#!/usr/bin/env python3
"""Sync the users tables between Pantry and Splitter, bidirectionally.

Both apps keep their own users table (same schema, same columns). This
script keeps them in sync so a user added to one app shows up in the
other, without duplicates.

Rules (Tony, Nov 20):
- Bidirectional: Pantry -> Splitter and Splitter -> Pantry.
- Dedupe key is email, case-insensitive. Both tables enforce it with
  UNIQUE COLLATE NOCASE.
- If a user exists in one app but not the other, insert them into the
  other. The target database assigns a new id; the source id is never
  preserved (ids are local to each database).
- If a user exists in both, merge. Prefer the more advanced status
  (verified > invited > waitlisted). For the other fields, prefer the
  earliest creation-time value and fill in anything missing; never
  clobber a value without a clear signal. The merge is convergent, so
  running the script repeatedly is a no-op once both sides agree.
- referred_by is a foreign key to users(id) inside one database, so it
  is never copied as an id. It is resolved by email: the referrer's
  email is looked up in the target database and that database's id is
  used. If the referrer is not in the target yet, referred_by is left
  NULL and a later run fills it in once the referrer has synced.

Concurrency: both databases are SQLite with WAL. The script sets a busy
timeout and takes an IMMEDIATE write lock per database, retrying a few
times if the app holds the lock. It is safe to run while the apps are
running.

If either users table does not exist yet (the migrations have not been
applied), the script logs that and exits 0 without doing anything, so
the cron can be installed before the tables are live.

Usage:
    sync-users.py [--pantry-db PATH] [--splitter-db PATH] [--dry-run]

Exit 0 on success (including the no-op when a table is missing).
"""

import argparse
import logging
import sqlite3
import sys
import time

DEFAULT_PANTRY_DB = "/opt/pantry/app.db"
DEFAULT_SPLITTER_DB = "/opt/splitter/app.db"

STATUS_RANK = {"waitlisted": 0, "invited": 1, "verified": 2}

USER_COLUMNS = [
    "id",
    "email",
    "status",
    "type",
    "source",
    "source_detail",
    "referred_by",
    "created_at",
    "verified_at",
    "deleted_at",
    "data_deleted",
]

# Columns copied verbatim on insert (referred_by is resolved separately).
INSERT_COLUMNS = [
    "email",
    "status",
    "type",
    "source",
    "source_detail",
    "referred_by",
    "created_at",
    "verified_at",
    "deleted_at",
    "data_deleted",
]


def table_exists(conn, name):
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        (name,),
    ).fetchone()
    return row is not None


def load_users(conn):
    """Return {email_lower: user dict} and {id: email_lower} for one DB."""
    rows = conn.execute(
        "SELECT " + ", ".join(USER_COLUMNS) + " FROM users"
    ).fetchall()
    by_email = {}
    by_id = {}
    for row in rows:
        user = dict(zip(USER_COLUMNS, row))
        key = (user["email"] or "").lower()
        by_email[key] = user
        by_id[user["id"]] = key
    return by_email, by_id


def referrer_email(user, by_id):
    """The referrer's email (lowercase) for a user, or None."""
    ref_id = user.get("referred_by")
    if ref_id is None:
        return None
    return by_id.get(ref_id)


def pick_earlier_side(a, b):
    """Which side's creation-time value wins: the earlier created_at.

    Returns "a" or "b". Ties go to "a" (Pantry) for determinism.
    """
    ca, cb = a.get("created_at") or "", b.get("created_at") or ""
    return "a" if ca <= cb else "b"


def merge_users(pantry_user, splitter_user):
    """Merge two rows for the same email into one record.

    Returns a dict of the merged field values (excluding id and
    referred_by, which are resolved per target database). Either
    argument may be None (user only in one app).
    """
    if pantry_user is None:
        return dict(splitter_user)
    if splitter_user is None:
        return dict(pantry_user)

    a, b = pantry_user, splitter_user
    winner = pick_earlier_side(a, b)
    early, late = (a, b) if winner == "a" else (b, a)

    merged = {}
    merged["email"] = a["email"]  # same address modulo case; keep Pantry's
    # Status: the more advanced one wins.
    merged["status"] = (
        a["status"]
        if STATUS_RANK.get(a["status"], 0) >= STATUS_RANK.get(b["status"], 0)
        else b["status"]
    )
    # verified_at: earliest non-null, if either side is verified.
    verified_ats = [v for v in (a.get("verified_at"), b.get("verified_at")) if v]
    merged["verified_at"] = min(verified_ats) if verified_ats else None
    # created_at: earliest.
    merged["created_at"] = min(
        v for v in (a.get("created_at"), b.get("created_at")) if v
    )
    # deleted_at: earliest non-null, else None.
    deleted_ats = [v for v in (a.get("deleted_at"), b.get("deleted_at")) if v]
    merged["deleted_at"] = min(deleted_ats) if deleted_ats else None
    # data_deleted: OR.
    merged["data_deleted"] = max(a.get("data_deleted") or 0, b.get("data_deleted") or 0)
    # Creation-time attributes (type, source, source_detail): prefer the
    # earlier-created side; fill a null from the other side.
    for col in ("type", "source", "source_detail"):
        if early.get(col) is not None:
            merged[col] = early[col]
        else:
            merged[col] = late.get(col)
    return merged


def resolve_referred_by(merged, referrer_key, target_by_email):
    """The referred_by id to store in the target DB, or None."""
    if referrer_key is None:
        return None
    target = target_by_email.get(referrer_key)
    return target["id"] if target is not None else None


def sync_one_direction(
    conn, target_by_email, merged_by_email, referrer_by_email, dry_run, log
):
    """Write merged records into one database. Returns (inserted, updated)."""
    inserted = 0
    updated = 0
    for key in sorted(merged_by_email, key=lambda k: merged_by_email[k]["created_at"] or ""):
        merged = merged_by_email[key]
        ref_key = referrer_by_email.get(key)
        existing = target_by_email.get(key)
        ref_id = resolve_referred_by(merged, ref_key, target_by_email)
        if existing is None:
            if dry_run:
                log.info("  would insert %s", merged["email"])
                inserted += 1
                continue
            cols = ", ".join(INSERT_COLUMNS)
            placeholders = ", ".join("?" for _ in INSERT_COLUMNS)
            values = []
            for col in INSERT_COLUMNS:
                if col == "referred_by":
                    values.append(ref_id)
                else:
                    values.append(merged.get(col))
            cur = conn.execute(
                f"INSERT INTO users ({cols}) VALUES ({placeholders})", values
            )
            # Make the new row visible to later resolutions in this run.
            target_by_email[key] = dict(merged, id=cur.lastrowid)
            inserted += 1
        else:
            # Build the row the target should have, and update only if
            # something differs.
            desired = dict(merged)
            desired["referred_by"] = ref_id
            changed = {
                col: desired.get(col)
                for col in INSERT_COLUMNS
                if col != "email" and existing.get(col) != desired.get(col)
            }
            if not changed:
                continue
            if dry_run:
                log.info("  would update %s: %s", merged["email"], sorted(changed))
                updated += 1
                continue
            assignments = ", ".join(f"{col} = ?" for col in changed)
            conn.execute(
                f"UPDATE users SET {assignments} WHERE id = ?",
                [*changed.values(), existing["id"]],
            )
            target_by_email[key] = dict(existing, **changed)
            updated += 1
    return inserted, updated


def run_sync(pantry_db, splitter_db, dry_run, log):
    pantry_conn = sqlite3.connect(pantry_db, timeout=10)
    splitter_conn = sqlite3.connect(splitter_db, timeout=10)
    try:
        for conn in (pantry_conn, splitter_conn):
            conn.execute("PRAGMA foreign_keys = ON")
            conn.execute("PRAGMA busy_timeout = 10000")

        if not table_exists(pantry_conn, "users"):
            log.info("Pantry users table does not exist yet; nothing to sync.")
            return 0
        if not table_exists(splitter_conn, "users"):
            log.info("Splitter users table does not exist yet; nothing to sync.")
            return 0

        pantry_by_email, pantry_by_id = load_users(pantry_conn)
        splitter_by_email, splitter_by_id = load_users(splitter_conn)
        log.info(
            "Loaded %d Pantry users, %d Splitter users.",
            len(pantry_by_email),
            len(splitter_by_email),
        )

        # Merge every email across both sides, and note each user's
        # referrer by email (resolved per target database later).
        merged_by_email = {}
        referrer_by_email = {}
        for key in sorted(set(pantry_by_email) | set(splitter_by_email)):
            p_user = pantry_by_email.get(key)
            s_user = splitter_by_email.get(key)
            merged_by_email[key] = merge_users(p_user, s_user)
            ref = None
            for user, by_id in ((p_user, pantry_by_id), (s_user, splitter_by_id)):
                if user is not None:
                    ref = referrer_email(user, by_id)
                    if ref is not None:
                        break
            referrer_by_email[key] = ref

        total_inserted = 0
        total_updated = 0
        # Write to each database in its own IMMEDIATE transaction so the
        # write lock is held briefly and a busy app can be retried.
        for label, conn, target_by_email in (
            ("Pantry", pantry_conn, pantry_by_email),
            ("Splitter", splitter_conn, splitter_by_email),
        ):
            for attempt in range(4):
                try:
                    if not dry_run:
                        conn.execute("BEGIN IMMEDIATE")
                    ins, upd = sync_one_direction(
                        conn,
                        target_by_email,
                        merged_by_email,
                        referrer_by_email,
                        dry_run,
                        log,
                    )
                    if not dry_run:
                        conn.commit()
                    log.info(
                        "%s: %d inserted, %d updated.", label, ins, upd
                    )
                    total_inserted += ins
                    total_updated += upd
                    break
                except sqlite3.OperationalError as exc:
                    if not dry_run:
                        try:
                            conn.rollback()
                        except sqlite3.Error:
                            pass
                    if "locked" in str(exc).lower() and attempt < 3:
                        log.warning(
                            "%s locked, retry %d/3 in 2s: %s",
                            label,
                            attempt + 1,
                            exc,
                        )
                        time.sleep(2)
                        continue
                    raise
        log.info(
            "Done. %d inserted, %d updated across both databases.",
            total_inserted,
            total_updated,
        )
        return 0
    finally:
        pantry_conn.close()
        splitter_conn.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pantry-db", default=DEFAULT_PANTRY_DB)
    parser.add_argument("--splitter-db", default=DEFAULT_SPLITTER_DB)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    log = logging.getLogger("sync-users")
    try:
        return run_sync(args.pantry_db, args.splitter_db, args.dry_run, log)
    except sqlite3.Error as exc:
        log.error("SQLite error: %s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
