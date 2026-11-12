-- New notification kinds, in their own migration: Postgres can't use an enum value
-- in the same transaction that adds it.
alter type public.notification_kind add value if not exists 'mention';
alter type public.notification_kind add value if not exists 'reply';
alter type public.notification_kind add value if not exists 'reaction';
