create index order_upgrade_requests_requested_by_idx
on public.order_upgrade_requests(requested_by) where requested_by is not null;

create index order_upgrade_requests_resolved_by_idx
on public.order_upgrade_requests(resolved_by) where resolved_by is not null;

create index order_upgrade_requests_extension_idx
on public.order_upgrade_requests(extension_id) where extension_id is not null;
