/* -*- mode: c; c-basic-offset: 8; indent-tabs-mode: nil; -*-
 * vim:expandtab:shiftwidth=8:tabstop=8:
 *
 *  Copyright (C) 2002 Cluster File Systems, Inc.
 *
 *   This file is part of Lustre, http://www.lustre.org.
 *
 *   Lustre is free software; you can redistribute it and/or
 *   modify it under the terms of version 2 of the GNU General Public
 *   License as published by the Free Software Foundation.
 *
 *   Lustre is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with Lustre; if not, write to the Free Software
 *   Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 *
 */

#define EXPORT_SYMTAB

#define DEBUG_SUBSYSTEM S_RPC

#include <linux/lustre_net.h>

static spinlock_t conn_lock;
static struct list_head conn_list;
static struct list_head conn_unused_list;

struct ptlrpc_connection *ptlrpc_get_connection(struct lustre_peer *peer)
{
        struct list_head *tmp, *pos;
        struct ptlrpc_connection *c;
        ENTRY;

        spin_lock(&conn_lock);
        list_for_each(tmp, &conn_list) {
                c = list_entry(tmp, struct ptlrpc_connection, c_link);
                if (memcmp(peer, &c->c_peer, sizeof(*peer)) == 0) {
                        atomic_inc(&c->c_refcount);
                        GOTO(out, c);
                }
        }

        list_for_each_safe(tmp, pos, &conn_unused_list) {
                c = list_entry(tmp, struct ptlrpc_connection, c_link);
                if (memcmp(peer, &c->c_peer, sizeof(*peer)) == 0) {
                        atomic_inc(&c->c_refcount);
                        list_del(&c->c_link);
                        list_add(&c->c_link, &conn_list);
                        GOTO(out, c);
                }
        }

        /* FIXME: this should be a slab once we can validate slab addresses
         * without OOPSing */
        OBD_ALLOC(c, sizeof(*c));
        if (c == NULL)
                GOTO(out, c);

        c->c_xid_in = 1;
        c->c_xid_out = 1;
        c->c_generation = 1;
        c->c_epoch = 1;
        c->c_bootcount = 0;
        atomic_set(&c->c_refcount, 1);
        spin_lock_init(&c->c_lock);

        memcpy(&c->c_peer, peer, sizeof(c->c_peer));
        list_add(&c->c_link, &conn_list);

        EXIT;
 out:
        spin_unlock(&conn_lock);
        return c;
}

int ptlrpc_put_connection(struct ptlrpc_connection *c)
{
        int rc = 0;

        if (atomic_dec_and_test(&c->c_refcount)) {
                spin_lock(&conn_lock);
                list_del(&c->c_link);
                list_add(&c->c_link, &conn_unused_list);
                spin_unlock(&conn_lock);
                rc = 1;
        }

        return rc;
}

struct ptlrpc_connection *ptlrpc_connection_addref(struct ptlrpc_connection *c)
{
        atomic_inc(&c->c_refcount);
        return c;
}

void ptlrpc_init_connection(void)
{
        INIT_LIST_HEAD(&conn_list);
        INIT_LIST_HEAD(&conn_unused_list);
        conn_lock = SPIN_LOCK_UNLOCKED;
}

void ptlrpc_cleanup_connection(void)
{
        struct list_head *tmp, *pos;
        struct ptlrpc_connection *c;

        spin_lock(&conn_lock);
        list_for_each_safe(tmp, pos, &conn_unused_list) {
                c = list_entry(tmp, struct ptlrpc_connection, c_link);
                list_del(&c->c_link);
                OBD_FREE(c, sizeof(*c));
        }
        list_for_each_safe(tmp, pos, &conn_list) {
                c = list_entry(tmp, struct ptlrpc_connection, c_link);
                CERROR("Connection %p has refcount %d at cleanup (nid=%lu)!\n",
                       c, atomic_read(&c->c_refcount),
                       (unsigned long)c->c_peer.peer_nid);
                list_del(&c->c_link);
                OBD_FREE(c, sizeof(*c));
        }
        spin_unlock(&conn_lock);
}
