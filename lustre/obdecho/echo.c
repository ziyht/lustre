/* -*- mode: c; c-basic-offset: 8; indent-tabs-mode: nil; -*-
 * vim:expandtab:shiftwidth=8:tabstop=8:
 *
 *  linux/fs/ext2_obd/ext2_obd.c
 *
 * Copyright (C) 2001  Cluster File Systems, Inc.
 *
 * This code is issued under the GNU General Public License.
 * See the file COPYING in this distribution
 *
 * by Peter Braam <braam@clusterfs.com>
 */

#define EXPORT_SYMTAB

#include <linux/version.h>
#include <linux/module.h>
#include <linux/fs.h>
#include <linux/stat.h>
#include <linux/locks.h>
#include <linux/ext2_fs.h>
#include <linux/quotaops.h>
#include <asm/unistd.h>

#define DEBUG_SUBSYSTEM S_ECHO

#include <linux/obd_support.h>
#include <linux/obd_class.h>
#include <linux/obd_echo.h>

extern struct obd_device obd_dev[MAX_OBD_DEVICES];
static struct obdo OA;
static obd_count GEN;
static long echo_pages = 0;

static int echo_connect(struct lustre_handle *conn, struct obd_device *obd)
{
        int rc;

        MOD_INC_USE_COUNT;
        rc = class_connect(conn, obd);

        if (rc)
                MOD_DEC_USE_COUNT;

        return rc;
}

static int echo_disconnect(struct lustre_handle *conn)
{
        int rc;

        rc = class_disconnect(conn);
        if (!rc)
                MOD_DEC_USE_COUNT;

        return rc;
}

static int echo_getattr(struct lustre_handle *conn, struct obdo *oa)
{
        memcpy(oa, &OA, sizeof(*oa));
        oa->o_mode = ++GEN;

        return 0;
}

int echo_preprw(int cmd, struct lustre_handle *conn, int objcount,
                struct obd_ioobj *obj, int niocount, struct niobuf_remote *nb,
                struct niobuf_local *res, void **desc_private)
{
        struct niobuf_local *r = res;
        int rc = 0;
        int i;

        ENTRY;

        memset(res, 0, sizeof(*res) * niocount);

        CDEBUG(D_PAGE, "%s %d obdos with %d IOs\n",
               cmd == OBD_BRW_READ ? "reading" : "writing", objcount, niocount);

        for (i = 0; i < objcount; i++, obj++) {
                int j;

                for (j = 0 ; j < obj->ioo_bufcnt ; j++, nb++, r++) {
                        unsigned long address;

                        address = get_zeroed_page(GFP_KERNEL);
                        if (!address) {
                                CERROR("can't get new page %d/%d for id %Ld\n",
                                       j, obj->ioo_bufcnt,
                                       (unsigned long long)obj->ioo_id);
                                GOTO(preprw_cleanup, rc = -ENOMEM);
                        }
                        echo_pages++;

                        r->offset = nb->offset;
                        r->page = virt_to_page(address);
                        r->addr = kmap(r->page);
                        r->len = nb->len;
                }
        }
        CDEBUG(D_PAGE, "%ld pages allocated after prep\n", echo_pages);

        RETURN(0);

preprw_cleanup:
        /* It is possible that we would rather handle errors by  allow
         * any already-set-up pages to complete, rather than tearing them
         * all down again.  I believe that this is what the in-kernel
         * prep/commit operations do.
         */
        CERROR("cleaning up %ld pages (%d obdos)\n", (long)(r - res), objcount);
        while (r-- > res) {
                kunmap(r->page);
                __free_pages(r->page, 0);
                echo_pages--;
        }
        memset(res, 0, sizeof(*res) * niocount);

        return rc;
}

int echo_commitrw(int cmd, struct lustre_handle *conn, int objcount,
                  struct obd_ioobj *obj, int niocount, struct niobuf_local *res,
                  void *desc_private)
{
        struct niobuf_local *r = res;
        int rc = 0;
        int i;
        ENTRY;

        CDEBUG(D_PAGE, "%s %d obdos with %d IOs\n",
               cmd == OBD_BRW_READ ? "reading" : "writing", objcount, niocount);

        if (niocount && !r) {
                CERROR("NULL res niobuf with niocount %d\n", niocount);
                RETURN(-EINVAL);
        }

        for (i = 0; i < objcount; i++, obj++) {
                int j;

                for (j = 0 ; j < obj->ioo_bufcnt ; j++, r++) {
                        struct page *page = r->page;
                        unsigned long addr;

                        if (!page ||
                            !(addr = (unsigned long)page_address(page)) ||
                            !kern_addr_valid(addr)) {

                                CERROR("bad page %p, id %Ld (%d), buf %d/%d\n",
                                       page, (unsigned long long)obj->ioo_id, i,
                                       j, obj->ioo_bufcnt);
                                GOTO(commitrw_cleanup, rc = -EFAULT);
                        }

                        kunmap(page);
                        __free_pages(page, 0);
                        echo_pages--;
                }
        }
        CDEBUG(D_PAGE, "%ld pages remain after commit\n", echo_pages);
        RETURN(0);

commitrw_cleanup:
        CERROR("cleaning up %ld pages (%d obdos)\n",
               niocount - (long)(r - res) - 1, objcount);
        while (++r < res + niocount) {
                struct page *page = r->page;

                kunmap(page);
                __free_pages(page, 0);
                echo_pages--;
        }
        return rc;
}

struct obd_ops echo_obd_ops = {
        o_connect:     echo_connect,
        o_disconnect:  echo_disconnect,
        o_getattr:     echo_getattr,
        o_preprw:      echo_preprw,
        o_commitrw:    echo_commitrw,
};

#define OBDECHO_VERSION "$Revision: 1.16 $"

static int __init obdecho_init(void)
{
        printk(KERN_INFO "Echo OBD driver " OBDECHO_VERSION " info@clusterfs.com\n");

        return class_register_type(&echo_obd_ops, OBD_ECHO_DEVICENAME);
}

static void __exit obdecho_exit(void)
{
        CERROR("%ld prep/commitrw pages leaked\n", echo_pages);
        class_unregister_type(OBD_ECHO_DEVICENAME);
}

MODULE_AUTHOR("Cluster Filesystems Inc. <info@clusterfs.com>");
MODULE_DESCRIPTION("Lustre Testing Echo OBD driver " OBDECHO_VERSION);
MODULE_LICENSE("GPL"); 

module_init(obdecho_init);
module_exit(obdecho_exit);
