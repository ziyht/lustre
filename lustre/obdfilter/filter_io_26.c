/* -*- mode: c; c-basic-offset: 8; indent-tabs-mode: nil; -*-
 * vim:expandtab:shiftwidth=8:tabstop=8:
 *
 * GPL HEADER START
 *
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 only,
 * as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License version 2 for more details (a copy is included
 * in the LICENSE file that accompanied this code).
 *
 * You should have received a copy of the GNU General Public License
 * version 2 along with this program; If not, see
 * http://www.sun.com/software/products/lustre/docs/GPLv2.pdf
 *
 * Please contact Sun Microsystems, Inc., 4150 Network Circle, Santa Clara,
 * CA 95054 USA or visit www.sun.com if you need additional information or
 * have any questions.
 *
 * GPL HEADER END
 */
/*
 * Copyright  2008 Sun Microsystems, Inc. All rights reserved
 * Use is subject to license terms.
 */
/*
 * This file is part of Lustre, http://www.lustre.org/
 * Lustre is a trademark of Sun Microsystems, Inc.
 *
 * lustre/obdfilter/filter_io_26.c
 *
 * Author: Peter Braam <braam@clusterfs.com>
 * Author: Andreas Dilger <adilger@clusterfs.com>
 * Author: Phil Schwan <phil@clusterfs.com>
 */

#ifndef AUTOCONF_INCLUDED
#include <linux/config.h>
#endif
#include <linux/module.h>
#include <linux/pagemap.h> // XXX kill me soon
#include <linux/version.h>
#include <linux/buffer_head.h>

#define DEBUG_SUBSYSTEM S_FILTER

#include <obd_class.h>
#include <lustre_fsfilt.h>
#include <lustre_quota.h>
#include "filter_internal.h"

/* 512byte block min */
#define MAX_BLOCKS_PER_PAGE (CFS_PAGE_SIZE / 512)
struct filter_iobuf {
        atomic_t          dr_numreqs;  /* number of reqs being processed */
        wait_queue_head_t dr_wait;
        int               dr_max_pages;
        int               dr_npages;
        int               dr_error;
        struct page     **dr_pages;
        unsigned long    *dr_blocks;
        unsigned int      dr_ignore_quota:1;
        struct filter_obd *dr_filter;
};

static void record_start_io(struct filter_iobuf *iobuf, int rw, int size,
                            struct obd_export *exp)
{
        struct filter_obd *filter = iobuf->dr_filter;

        atomic_inc(&iobuf->dr_numreqs);

        if (rw == OBD_BRW_READ) {
                atomic_inc(&filter->fo_r_in_flight);
                lprocfs_oh_tally(&filter->fo_filter_stats.hist[BRW_R_RPC_HIST],
                                 atomic_read(&filter->fo_r_in_flight));
                lprocfs_oh_tally_log2(&filter->fo_filter_stats.hist[BRW_R_DISK_IOSIZE],
                                      size);
                lprocfs_oh_tally(&exp->exp_filter_data.fed_brw_stats.hist[BRW_R_RPC_HIST],
                                 atomic_read(&filter->fo_r_in_flight));
                lprocfs_oh_tally_log2(&exp->exp_filter_data.fed_brw_stats.hist[BRW_R_DISK_IOSIZE], size);
        } else {
                atomic_inc(&filter->fo_w_in_flight);
                lprocfs_oh_tally(&filter->fo_filter_stats.hist[BRW_W_RPC_HIST],
                                 atomic_read(&filter->fo_w_in_flight));
                lprocfs_oh_tally_log2(&filter->fo_filter_stats.hist[BRW_W_DISK_IOSIZE],
                                      size);
                lprocfs_oh_tally(&exp->exp_filter_data.fed_brw_stats.hist[BRW_W_RPC_HIST],
                                 atomic_read(&filter->fo_w_in_flight));
                lprocfs_oh_tally_log2(&exp->exp_filter_data.fed_brw_stats.hist[BRW_W_DISK_IOSIZE], size);
        }
}

static void record_finish_io(struct filter_iobuf *iobuf, int rw, int rc)
{
        struct filter_obd *filter = iobuf->dr_filter;

        /* CAVEAT EMPTOR: possibly in IRQ context 
         * DO NOT record procfs stats here!!! */

        if (rw == OBD_BRW_READ)
                atomic_dec(&filter->fo_r_in_flight);
        else
                atomic_dec(&filter->fo_w_in_flight);

        if (atomic_dec_and_test(&iobuf->dr_numreqs))
                wake_up(&iobuf->dr_wait);
}

static int dio_complete_routine(struct bio *bio, unsigned int done, int error)
{
        struct filter_iobuf *iobuf = bio->bi_private;
        struct bio_vec *bvl;
        int i;

        /* CAVEAT EMPTOR: possibly in IRQ context 
         * DO NOT record procfs stats here!!! */

        if (bio->bi_size)                       /* Not complete */
                return 1;

        if (unlikely(iobuf == NULL)) {
                CERROR("***** bio->bi_private is NULL!  This should never "
                       "happen.  Normally, I would crash here, but instead I "
                       "will dump the bio contents to the console.  Please "
                       "report this to <http://bugzilla.lustre.org/> , along "
                       "with any interesting messages leading up to this point "
                       "(like SCSI errors, perhaps).  Because bi_private is "
                       "NULL, I can't wake up the thread that initiated this "
                       "I/O -- so you will probably have to reboot this node.\n");
                CERROR("bi_next: %p, bi_flags: %lx, bi_rw: %lu, bi_vcnt: %d, "
                       "bi_idx: %d, bi->size: %d, bi_end_io: %p, bi_cnt: %d, "
                       "bi_private: %p\n", bio->bi_next, bio->bi_flags,
                       bio->bi_rw, bio->bi_vcnt, bio->bi_idx, bio->bi_size,
                       bio->bi_end_io, atomic_read(&bio->bi_cnt),
                       bio->bi_private);
                return 0;
        }

        /* the check is outside of the cycle for performance reason -bzzz */
        if (!test_bit(BIO_RW, &bio->bi_rw)) {
                bio_for_each_segment(bvl, bio, i) {
                        if (likely(error == 0))
                                SetPageUptodate(bvl->bv_page);
                        LASSERT(PageLocked(bvl->bv_page));
#ifdef HAVE_PAGE_CONSTANT
                        ClearPageConstant(bvl->bv_page);
#endif
                }
                record_finish_io(iobuf, OBD_BRW_READ, error);
        } else {
#ifdef HAVE_PAGE_CONSTANT
                if (mapping_cap_page_constant_write(iobuf->dr_pages[0]->mapping)){
                        bio_for_each_segment(bvl, bio, i) {
                                ClearPageConstant(bvl->bv_page);
                        }
                }
#endif
                record_finish_io(iobuf, OBD_BRW_WRITE, error);
        }

        /* any real error is good enough -bzzz */
        if (error != 0 && iobuf->dr_error == 0)
                iobuf->dr_error = error;

        /* Completed bios used to be chained off iobuf->dr_bios and freed in
         * filter_clear_dreq().  It was then possible to exhaust the biovec-256
         * mempool when serious on-disk fragmentation was encountered,
         * deadlocking the OST.  The bios are now released as soon as complete
         * so the pool cannot be exhausted while IOs are competing. bug 10076 */
        bio_put(bio);
        return 0;
}

static int can_be_merged(struct bio *bio, sector_t sector)
{
        unsigned int size;

        if (!bio)
                return 0;

        size = bio->bi_size >> 9;
        return bio->bi_sector + size == sector ? 1 : 0;
}

struct filter_iobuf *filter_alloc_iobuf(struct filter_obd *filter,
                                        int rw, int num_pages)
{
        struct filter_iobuf *iobuf;

        LASSERTF(rw == OBD_BRW_WRITE || rw == OBD_BRW_READ, "%x\n", rw);

        OBD_ALLOC(iobuf, sizeof(*iobuf));
        if (iobuf == NULL)
                goto failed_0;

        OBD_ALLOC(iobuf->dr_pages, num_pages * sizeof(*iobuf->dr_pages));
        if (iobuf->dr_pages == NULL)
                goto failed_1;

        OBD_ALLOC(iobuf->dr_blocks,
                  MAX_BLOCKS_PER_PAGE * num_pages * sizeof(*iobuf->dr_blocks));
        if (iobuf->dr_blocks == NULL)
                goto failed_2;

        iobuf->dr_filter = filter;
        init_waitqueue_head(&iobuf->dr_wait);
        atomic_set(&iobuf->dr_numreqs, 0);
        iobuf->dr_max_pages = num_pages;
        iobuf->dr_npages = 0;
        iobuf->dr_error = 0;

        RETURN(iobuf);

 failed_2:
        OBD_FREE(iobuf->dr_pages,
                 num_pages * sizeof(*iobuf->dr_pages));
 failed_1:
        OBD_FREE(iobuf, sizeof(*iobuf));
 failed_0:
        RETURN(ERR_PTR(-ENOMEM));
}

static void filter_clear_iobuf(struct filter_iobuf *iobuf)
{
        iobuf->dr_npages = 0;
        iobuf->dr_error = 0;
        atomic_set(&iobuf->dr_numreqs, 0);
}

void filter_free_iobuf(struct filter_iobuf *iobuf)
{
        int num_pages = iobuf->dr_max_pages;

        filter_clear_iobuf(iobuf);

        OBD_FREE(iobuf->dr_blocks,
                 MAX_BLOCKS_PER_PAGE * num_pages * sizeof(*iobuf->dr_blocks));
        OBD_FREE(iobuf->dr_pages,
                 num_pages * sizeof(*iobuf->dr_pages));
        OBD_FREE_PTR(iobuf);
}

void filter_iobuf_put(struct filter_obd *filter, struct filter_iobuf *iobuf,
                      struct obd_trans_info *oti)
{
        int thread_id = oti ? oti->oti_thread_id : -1;

        if (unlikely(thread_id < 0)) {
                filter_free_iobuf(iobuf);
                return;
        }

        LASSERTF(filter->fo_iobuf_pool[thread_id] == iobuf,
                 "iobuf mismatch for thread %d: pool %p iobuf %p\n",
                 thread_id, filter->fo_iobuf_pool[thread_id], iobuf);
        filter_clear_iobuf(iobuf);
}

int filter_iobuf_add_page(struct obd_device *obd, struct filter_iobuf *iobuf,
                          struct inode *inode, struct page *page)
{
        LASSERT(iobuf->dr_npages < iobuf->dr_max_pages);
        iobuf->dr_pages[iobuf->dr_npages++] = page;

        return 0;
}

int filter_do_bio(struct obd_export *exp, struct inode *inode,
                  struct filter_iobuf *iobuf, int rw)
{
        struct obd_device *obd = exp->exp_obd;
        int            blocks_per_page = CFS_PAGE_SIZE >> inode->i_blkbits;
        struct page  **pages = iobuf->dr_pages;
        int            npages = iobuf->dr_npages;
        unsigned long *blocks = iobuf->dr_blocks;
        int            total_blocks = npages * blocks_per_page;
        int            sector_bits = inode->i_sb->s_blocksize_bits - 9;
        unsigned int   blocksize = inode->i_sb->s_blocksize;
        struct bio    *bio = NULL;
        int            frags = 0;
        unsigned long  start_time = jiffies;
        struct page   *page;
        unsigned int   page_offset;
        sector_t       sector;
        int            nblocks;
        int            block_idx;
        int            page_idx;
        int            i;
        int            rc = 0;
        ENTRY;

        LASSERT(iobuf->dr_npages == npages);
        LASSERT(total_blocks <= OBDFILTER_CREATED_SCRATCHPAD_ENTRIES);

        for (page_idx = 0, block_idx = 0;
             page_idx < npages;
             page_idx++, block_idx += blocks_per_page) {

                page = pages[page_idx];
                LASSERT (block_idx + blocks_per_page <= total_blocks);

                for (i = 0, page_offset = 0;
                     i < blocks_per_page;
                     i += nblocks, page_offset += blocksize * nblocks) {

                        nblocks = 1;

                        if (blocks[block_idx + i] == 0) {  /* hole */
                                LASSERT(rw == OBD_BRW_READ);
                                memset(kmap(page) + page_offset, 0, blocksize);
                                kunmap(page);
                                continue;
                        }

                        sector = (sector_t)blocks[block_idx + i] << sector_bits;

                        /* Additional contiguous file blocks? */
                        while (i + nblocks < blocks_per_page &&
                               (sector + (nblocks << sector_bits)) ==
                               ((sector_t)blocks[block_idx + i + nblocks] <<
                                sector_bits))
                                nblocks++;

#ifdef HAVE_PAGE_CONSTANT
                        /* I only set the page to be constant only if it 
                         * is mapped to a contiguous underlying disk block(s). 
                         * It will then make sure the corresponding device 
                         * cache of raid5 will be overwritten by this page. 
                         * - jay */
                        if ((rw == OBD_BRW_WRITE) && 
                            (nblocks == blocks_per_page) && 
                            mapping_cap_page_constant_write(inode->i_mapping))
                               SetPageConstant(page);
#endif

                        if (bio != NULL &&
                            can_be_merged(bio, sector) &&
                            bio_add_page(bio, page,
                                         blocksize * nblocks, page_offset) != 0)
                                continue;       /* added this frag OK */

                        if (bio != NULL) {
                                request_queue_t *q =
                                        bdev_get_queue(bio->bi_bdev);

                                /* Dang! I have to fragment this I/O */
                                CDEBUG(D_INODE, "bio++ sz %d vcnt %d(%d) "
                                       "sectors %d(%d) psg %d(%d) hsg %d(%d)\n",
                                       bio->bi_size,
                                       bio->bi_vcnt, bio->bi_max_vecs,
                                       bio->bi_size >> 9, q->max_sectors,
                                       bio_phys_segments(q, bio),
                                       q->max_phys_segments,
                                       bio_hw_segments(q, bio),
                                       q->max_hw_segments);

                                record_start_io(iobuf, rw, bio->bi_size, exp);
                                rc = fsfilt_send_bio(rw, obd, inode, bio);
                                if (rc < 0) {
                                        CERROR("Can't send bio: %d\n", rc);
                                        record_finish_io(iobuf, rw, rc);
                                        goto out;
                                }
                                frags++;
                        }

                        /* allocate new bio */
                        bio = bio_alloc(GFP_NOIO,
                                        (npages - page_idx) * blocks_per_page);
                        if (bio == NULL) {
                                CERROR("Can't allocate bio %u*%u = %u pages\n",
                                       (npages - page_idx), blocks_per_page,
                                       (npages - page_idx) * blocks_per_page);
                                rc = -ENOMEM;
                                goto out;
                        }

                        bio->bi_bdev = inode->i_sb->s_bdev;
                        bio->bi_sector = sector;
                        bio->bi_end_io = dio_complete_routine;
                        bio->bi_private = iobuf;

                        rc = bio_add_page(bio, page,
                                          blocksize * nblocks, page_offset);
                        LASSERT (rc != 0);
                }
        }

        if (bio != NULL) {
                record_start_io(iobuf, rw, bio->bi_size, exp);
                rc = fsfilt_send_bio(rw, obd, inode, bio);
                if (rc >= 0) {
                        frags++;
                        rc = 0;
                } else {
                        CERROR("Can't send bio: %d\n", rc);
                        record_finish_io(iobuf, rw, rc);
                }
        }

 out:
        wait_event(iobuf->dr_wait, atomic_read(&iobuf->dr_numreqs) == 0);

        if (rw == OBD_BRW_READ) {
                lprocfs_oh_tally(&obd->u.filter.fo_filter_stats.hist[BRW_R_DIO_FRAGS],
                                 frags);
                lprocfs_oh_tally(&exp->exp_filter_data.fed_brw_stats.hist[BRW_R_DIO_FRAGS],
                                 frags);
                lprocfs_oh_tally_log2(&obd->u.filter.fo_filter_stats.hist[BRW_R_IO_TIME],
                                      jiffies - start_time);
                lprocfs_oh_tally_log2(&exp->exp_filter_data.fed_brw_stats.hist[BRW_R_IO_TIME], jiffies - start_time);
                if (exp->exp_nid_stats && exp->exp_nid_stats->nid_brw_stats) {
                        lprocfs_oh_tally(&exp->exp_nid_stats->nid_brw_stats->hist[BRW_R_DIO_FRAGS],
                                         frags);
                        lprocfs_oh_tally_log2(&exp->exp_nid_stats->nid_brw_stats->hist[BRW_R_IO_TIME],
                                              jiffies - start_time);
                }
        } else {
                lprocfs_oh_tally(&obd->u.filter.fo_filter_stats.hist[BRW_W_DIO_FRAGS],
                                 frags);
                lprocfs_oh_tally(&exp->exp_filter_data.fed_brw_stats.hist[BRW_W_DIO_FRAGS],
                                 frags);
                lprocfs_oh_tally_log2(&obd->u.filter.fo_filter_stats.hist[BRW_W_IO_TIME],
                                      jiffies - start_time);
                lprocfs_oh_tally_log2(&exp->exp_filter_data.fed_brw_stats.hist[BRW_W_IO_TIME], jiffies - start_time);
                if (exp->exp_nid_stats && exp->exp_nid_stats->nid_brw_stats) {
                        lprocfs_oh_tally(&exp->exp_nid_stats->nid_brw_stats->hist[BRW_W_DIO_FRAGS],
                                         frags);
                        lprocfs_oh_tally_log2(&exp->exp_nid_stats->nid_brw_stats->hist[BRW_W_IO_TIME],
                                              jiffies - start_time);
                }
        }

        if (rc == 0)
                rc = iobuf->dr_error;
        RETURN(rc);
}

/* Must be called with i_mutex taken for writes; this will drop it */
int filter_direct_io(int rw, struct dentry *dchild, struct filter_iobuf *iobuf,
                     struct obd_export *exp, struct iattr *attr,
                     struct obd_trans_info *oti, void **wait_handle)
{
        struct obd_device *obd = exp->exp_obd;
        struct inode *inode = dchild->d_inode;
        int blocks_per_page = CFS_PAGE_SIZE >> inode->i_blkbits;
        int rc, rc2, create;
        struct semaphore *sem;
        ENTRY;

        LASSERTF(iobuf->dr_npages <= iobuf->dr_max_pages, "%d,%d\n",
                 iobuf->dr_npages, iobuf->dr_max_pages);
        LASSERT(iobuf->dr_npages <= OBDFILTER_CREATED_SCRATCHPAD_ENTRIES);

        if (rw == OBD_BRW_READ) {
                if (iobuf->dr_npages == 0)
                        RETURN(0);
                create = 0;
                sem = NULL;
        } else {
                LASSERTF(rw == OBD_BRW_WRITE, "%x\n", rw);
                LASSERT(iobuf->dr_npages > 0);
                create = 1;
                sem = &obd->u.filter.fo_alloc_lock;

                lquota_enforce(filter_quota_interface_ref, obd, iobuf->dr_ignore_quota);
        }

        rc = fsfilt_map_inode_pages(obd, inode, iobuf->dr_pages,
                                    iobuf->dr_npages, iobuf->dr_blocks,
                                    obdfilter_created_scratchpad, create, sem);

        if (rw == OBD_BRW_WRITE) {
                if (rc == 0) {
                        filter_tally(exp, iobuf->dr_pages,
                                     iobuf->dr_npages, iobuf->dr_blocks,
                                     blocks_per_page, 1);
                        if (attr->ia_size > i_size_read(inode))
                                attr->ia_valid |= ATTR_SIZE;
                        rc = fsfilt_setattr(obd, dchild,
                                            oti->oti_handle, attr, 0);
                }

                UNLOCK_INODE_MUTEX(inode);

                rc2 = filter_finish_transno(exp, oti, 0, 0);
                if (rc2 != 0) {
                        CERROR("can't close transaction: %d\n", rc2);
                        if (rc == 0)
                                rc = rc2;
                }

                rc2 = fsfilt_commit_async(obd,inode,oti->oti_handle,
                                          wait_handle);
                if (rc == 0)
                        rc = rc2;
                if (rc != 0)
                        RETURN(rc);
        } else if (rc == 0) {
                filter_tally(exp, iobuf->dr_pages, iobuf->dr_npages,
                             iobuf->dr_blocks, blocks_per_page, 0);
        }

        RETURN(filter_do_bio(exp, inode, iobuf, rw));
}

/* See if there are unallocated parts in given file region */
static int filter_range_is_mapped(struct inode *inode, obd_size offset, int len)
{
        sector_t (*fs_bmap)(struct address_space *, sector_t) =
                inode->i_mapping->a_ops->bmap;
        int j;

        /* We can't know if we are overwriting or not */
        if (fs_bmap == NULL)
                return 0;

        offset >>= inode->i_blkbits;
        len >>= inode->i_blkbits;

        for (j = 0; j <= len; j++)
                if (fs_bmap(inode->i_mapping, offset + j) == 0)
                        return 0;

        return 1;
}

/*
 * interesting use cases on how it interacts with VM:
 *
 * - vm writeout -- shouldn't see our pages as we don't mark them dirty
 *   though vm can find partial page left dirty by truncate. in this
 *   usual writeout is used unless our write rewrite that page - then we
 *   drop PG_dirty with PG_lock held.
 *
 * - else?
 *
 */
int filter_commitrw_write(struct obd_export *exp, struct obdo *oa,
                          int objcount, struct obd_ioobj *obj,
                          struct niobuf_remote *nb, int niocount,
                          struct niobuf_local *res, struct obd_trans_info *oti,
                          int rc)
{
        struct niobuf_local *lnb;
        struct filter_iobuf *iobuf = NULL;
        struct lvfs_run_ctxt saved;
        struct fsfilt_objinfo fso;
        struct iattr iattr = { 0 };
        struct inode *inode = NULL;
        unsigned long now = jiffies;
        int i, err, cleanup_phase = 0;
        struct obd_device *obd = exp->exp_obd;
        struct filter_obd *fo = &obd->u.filter;
        void *wait_handle;
        int   total_size = 0, rc2;
        unsigned int qcids[MAXQUOTAS] = {0, 0};
        ENTRY;

        LASSERT(oti != NULL);
        LASSERT(objcount == 1);
        LASSERT(current->journal_info == NULL);

        if (rc != 0)
                GOTO(cleanup, rc);

        /* Unfortunately, if quota master is too busy to handle the
         * pre-dqacq in time and quota hash on ost is used up, we
         * have to wait for the completion of in flight dqacq/dqrel,
         * then try again */
        if ((rc2 = lquota_chkquota(filter_quota_interface_ref, obd, oa->o_uid,
                                   oa->o_gid, niocount)) == QUOTA_RET_ACQUOTA) {
                OBD_FAIL_TIMEOUT(OBD_FAIL_OST_HOLD_WRITE_RPC, 90);
                lquota_acquire(filter_quota_interface_ref, obd, oa->o_uid,
                               oa->o_gid);
        }

        if (rc2 < 0) {
                rc = rc2;
                GOTO(cleanup, rc);
        }

        iobuf = filter_iobuf_get(&obd->u.filter, oti);
        if (IS_ERR(iobuf))
                GOTO(cleanup, rc = PTR_ERR(iobuf));
        cleanup_phase = 1;

        fso.fso_dentry = res->dentry;
        fso.fso_bufcnt = obj->ioo_bufcnt;
        inode = res->dentry->d_inode;

        iobuf->dr_ignore_quota = 0;
        for (i = 0, lnb = res; i < niocount; i++, lnb++) {
                loff_t this_size;

                /* If overwriting an existing block, we don't need a grant */
                if (!(lnb->flags & OBD_BRW_GRANTED) && lnb->rc == -ENOSPC &&
                    filter_range_is_mapped(inode, lnb->offset, lnb->len))
                        lnb->rc = 0;

                if (lnb->rc) { /* ENOSPC, network RPC error, etc. */
                        CDEBUG(D_INODE, "Skipping [%d] == %d\n", i, lnb->rc);
                        continue;
                }

                LASSERT(PageLocked(lnb->page));
                LASSERT(!PageWriteback(lnb->page));

                /* truncate might leave tail dirty */
                clear_page_dirty_for_io(lnb->page);

                SetPageUptodate(lnb->page);

                err = filter_iobuf_add_page(obd, iobuf, inode, lnb->page);
                LASSERT (err == 0);

                total_size += lnb->len;

                /* we expect these pages to be in offset order, but we'll
                 * be forgiving */
                this_size = lnb->offset + lnb->len;
                if (this_size > iattr.ia_size)
                        iattr.ia_size = this_size;

                /* if one page is a write-back page from client cache, or it's
                 * written by root, then mark the whole io request as ignore
                 * quota request */
                if (lnb->flags & (OBD_BRW_FROM_GRANT | OBD_BRW_NOQUOTA))
                        iobuf->dr_ignore_quota = 1;
        }

        push_ctxt(&saved, &obd->obd_lvfs_ctxt, NULL);
        cleanup_phase = 2;

        DQUOT_INIT(inode);

        LOCK_INODE_MUTEX(inode);
        fsfilt_check_slow(obd, now, "i_mutex");
        oti->oti_handle = fsfilt_brw_start(obd, objcount, &fso, niocount, res,
                                           oti);
        if (IS_ERR(oti->oti_handle)) {
                UNLOCK_INODE_MUTEX(inode);
                rc = PTR_ERR(oti->oti_handle);
                CDEBUG(rc == -ENOSPC ? D_INODE : D_ERROR,
                       "error starting transaction: rc = %d\n", rc);
                oti->oti_handle = NULL;
                GOTO(cleanup, rc);
        }
        /* have to call fsfilt_commit() from this point on */

        fsfilt_check_slow(obd, now, "brw_start");

        i = OBD_MD_FLATIME | OBD_MD_FLMTIME | OBD_MD_FLCTIME;

        /* If the inode still has SUID+SGID bits set (see filter_precreate())
         * then we will accept the UID+GID if sent by the client for
         * initializing the ownership of this inode.  We only allow this to
         * happen once (so clear these bits) and later only allow setattr. */
        if (inode->i_mode & S_ISUID)
                i |= OBD_MD_FLUID;
        if (inode->i_mode & S_ISGID)
                i |= OBD_MD_FLGID;

        iattr_from_obdo(&iattr, oa, i);
        if (iattr.ia_valid & (ATTR_UID | ATTR_GID)) {
                unsigned int save;

                CDEBUG(D_INODE, "update UID/GID to %lu/%lu\n",
                       (unsigned long)oa->o_uid, (unsigned long)oa->o_gid);

                cfs_cap_raise(CFS_CAP_SYS_RESOURCE);

                iattr.ia_valid |= ATTR_MODE;
                iattr.ia_mode = inode->i_mode;
                if (iattr.ia_valid & ATTR_UID)
                        iattr.ia_mode &= ~S_ISUID;
                if (iattr.ia_valid & ATTR_GID)
                        iattr.ia_mode &= ~S_ISGID;

                rc = filter_update_fidea(exp, inode, oti->oti_handle, oa);

                /* To avoid problems with quotas, UID and GID must be set
                 * in the inode before filter_direct_io() - see bug 10357. */
                save = iattr.ia_valid;
                iattr.ia_valid &= (ATTR_UID | ATTR_GID);
                rc = fsfilt_setattr(obd, res->dentry, oti->oti_handle, &iattr, 0);
                CDEBUG(D_QUOTA, "set uid(%u)/gid(%u) to ino(%lu). rc(%d)\n", 
                                iattr.ia_uid, iattr.ia_gid, inode->i_ino, rc);
                iattr.ia_valid = save & ~(ATTR_UID | ATTR_GID);
        }

        /* filter_direct_io drops i_mutex */
        rc = filter_direct_io(OBD_BRW_WRITE, res->dentry, iobuf, exp, &iattr,
                              oti, &wait_handle);
        if (rc == 0)
                obdo_from_inode(oa, inode,
                                FILTER_VALID_FLAGS |OBD_MD_FLUID |OBD_MD_FLGID);
        else
                obdo_from_inode(oa, inode, OBD_MD_FLUID | OBD_MD_FLGID);

        lquota_getflag(filter_quota_interface_ref, obd, oa);

        fsfilt_check_slow(obd, now, "direct_io");

        err = fsfilt_commit_wait(obd, inode, wait_handle);
        if (err) {
                CERROR("Failure to commit OST transaction (%d)?\n", err);
                rc = err;
        }

        if (obd->obd_replayable && !rc)
                LASSERTF(oti->oti_transno <= obd->obd_last_committed,
                         "oti_transno "LPU64" last_committed "LPU64"\n",
                         oti->oti_transno, obd->obd_last_committed);

        fsfilt_check_slow(obd, now, "commitrw commit");

cleanup:
        filter_grant_commit(exp, niocount, res);

        switch (cleanup_phase) {
        case 2:
                pop_ctxt(&saved, &obd->obd_lvfs_ctxt, NULL);
                LASSERT(current->journal_info == NULL);
        case 1:
                filter_iobuf_put(&obd->u.filter, iobuf, oti);
        case 0:
                /*
                 * lnb->page automatically returns back into per-thread page
                 * pool (bug 5137)
                 */
                f_dput(res->dentry);
        }

        /* trigger quota pre-acquire */
        qcids[USRQUOTA] = oa->o_uid;
        qcids[GRPQUOTA] = oa->o_gid;
        err = lquota_adjust(filter_quota_interface_ref, obd, qcids, NULL, rc,
                            FSFILT_OP_CREATE);
        CDEBUG(err ? D_ERROR : D_QUOTA,
               "filter adjust qunit! (rc:%d)\n", err);

        for (i = 0, lnb = res; i < niocount; i++, lnb++) {
                if (lnb->page == NULL)
                        continue;

                LASSERT(PageLocked(lnb->page));
                unlock_page(lnb->page);

                page_cache_release(lnb->page);
                lnb->page = NULL;
        }

        if (inode && (fo->fo_writethrough_cache == 0 ||
                        i_size_read(inode) > fo->fo_readcache_max_filesize))
                filter_invalidate_cache(obd, obj, nb, inode);

        RETURN(rc);
}
