-- HOOD BUOYZ Supabase setup. Run once in the Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create or replace function public.is_store_admin()
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select exists(select 1 from public.admin_users where user_id = auth.uid()) $$;
revoke all on function public.is_store_admin() from public;
grant execute on function public.is_store_admin() to anon, authenticated;

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(name) between 1 and 120),
  category text not null check (category in ('T-shirts','Hoodies','Caps','Accessories')),
  collection text not null check (collection in ('Gaming','Music','Lifestyle')),
  price numeric(10,2) not null check (price > 0),
  stock integer not null default 0 check (stock >= 0),
  colors text[] not null default '{}',
  sizes text[] not null default '{}',
  description text not null default '',
  image_url text not null default '',
  badge text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists products_active_created_idx on public.products(active, created_at desc);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null check (length(customer_name) between 1 and 120),
  email text not null check (length(email) between 3 and 254),
  phone text not null check (length(phone) between 3 and 40),
  address text not null check (length(address) between 5 and 500),
  total numeric(10,2) not null check (total >= 0),
  status text not null default 'pending' check (status in ('pending','confirmed','processing','shipped','completed','cancelled')),
  created_at timestamptz not null default now()
);
create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  size text not null,
  color text not null,
  quantity integer not null check (quantity > 0),
  unit_price numeric(10,2) not null check (unit_price > 0)
);

alter table public.admin_users enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
drop policy if exists "admins can read own admin record" on public.admin_users;
create policy "admins can read own admin record" on public.admin_users for select to authenticated using (user_id = auth.uid());
drop policy if exists "public can view active products" on public.products;
create policy "public can view active products" on public.products for select to anon, authenticated using (active or public.is_store_admin());
drop policy if exists "admins manage products" on public.products;
create policy "admins manage products" on public.products for all to authenticated using (public.is_store_admin()) with check (public.is_store_admin());
drop policy if exists "admins view orders" on public.orders;
create policy "admins view orders" on public.orders for select to authenticated using (public.is_store_admin());
drop policy if exists "admins update orders" on public.orders;
create policy "admins update orders" on public.orders for update to authenticated using (public.is_store_admin()) with check (public.is_store_admin());
drop policy if exists "admins view order items" on public.order_items;
create policy "admins view order items" on public.order_items for select to authenticated using (public.is_store_admin());

grant select on public.products to anon, authenticated;
grant insert, update, delete on public.products to authenticated;
grant select on public.admin_users to authenticated;
grant select, update on public.orders to authenticated;
grant select on public.order_items to authenticated;
revoke all on public.orders, public.order_items from anon, authenticated;
grant select, update on public.orders to authenticated;
grant select on public.order_items to authenticated;

-- Guest checkout is the only public write path. It takes prices from the DB,
-- locks stock rows, and snapshots product information into each order item.
create or replace function public.submit_customer_order(
  p_customer_name text, p_email text, p_phone text, p_address text, p_items jsonb
) returns uuid language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  new_order_id uuid := gen_random_uuid();
  item jsonb;
  product_row public.products%rowtype;
  item_qty integer;
  item_size text;
  item_color text;
  calculated_total numeric(10,2) := 0;
begin
  if length(trim(p_customer_name)) not between 1 and 120 or length(trim(p_email)) not between 3 and 254
    or length(trim(p_phone)) not between 3 and 40 or length(trim(p_address)) not between 5 and 500 then
    raise exception 'Please provide valid contact and delivery details.';
  end if;
  if p_items is null or jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'Your bag is empty or invalid.';
  end if;
  if jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 30 then
    raise exception 'Your bag is empty or contains too many line items.';
  end if;
  for item in select value from jsonb_array_elements(p_items) loop
    item_qty := (item->>'quantity')::integer;
    item_size := left(trim(item->>'size'), 30);
    item_color := left(trim(item->>'color'), 60);
    if item_qty < 1 or item_qty > 20 then raise exception 'Invalid item quantity.'; end if;
    select * into product_row from public.products where id = (item->>'product_id')::uuid and active = true for update;
    if not found then raise exception 'A product in your bag is no longer available.'; end if;
    if not (item_size = any(product_row.sizes)) or not (item_color = any(product_row.colors)) then raise exception 'A selected size or colour is unavailable.'; end if;
    if product_row.stock < item_qty then raise exception 'Not enough stock for %.', product_row.name; end if;
    update public.products set stock = stock - item_qty, updated_at = now() where id = product_row.id;
    calculated_total := calculated_total + product_row.price * item_qty;
  end loop;
  insert into public.orders(id, customer_name, email, phone, address, total)
  values(new_order_id, trim(p_customer_name), trim(p_email), trim(p_phone), trim(p_address), calculated_total);
  for item in select value from jsonb_array_elements(p_items) loop
    item_qty := (item->>'quantity')::integer; item_size := left(trim(item->>'size'),30); item_color := left(trim(item->>'color'),60);
    select * into product_row from public.products where id = (item->>'product_id')::uuid;
    insert into public.order_items(order_id, product_id, product_name, size, color, quantity, unit_price)
    values(new_order_id, product_row.id, product_row.name, item_size, item_color, item_qty, product_row.price);
  end loop;
  return new_order_id;
end;
$$;
revoke all on function public.submit_customer_order(text,text,text,text,jsonb) from public;
grant execute on function public.submit_customer_order(text,text,text,text,jsonb) to anon, authenticated;

-- Product image bucket is public for storefront image reads; only allowlisted
-- administrators may upload, replace, or delete objects.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('product-images','product-images',true,8388608,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 8388608, allowed_mime_types = array['image/jpeg','image/png','image/webp'];
drop policy if exists "public read product images" on storage.objects;
create policy "public read product images" on storage.objects for select to anon, authenticated using (bucket_id = 'product-images');
drop policy if exists "admins manage product images" on storage.objects;
create policy "admins manage product images" on storage.objects for all to authenticated using (bucket_id = 'product-images' and public.is_store_admin()) with check (bucket_id = 'product-images' and public.is_store_admin());

-- Sample catalogue for the supplied storefront. Remove these after adding live inventory.
insert into public.products(id,name,category,collection,price,stock,colors,sizes,description,image_url,badge) values
('10000000-0000-4000-8000-000000000001','AFK? NEVER TEE','T-shirts','Gaming',42,25,array['Washed black'],array['S','M','L','XL','XXL'],'For the ones who say one more game at 2AM. Heavyweight cotton with a relaxed, boxy fit.','https://images.unsplash.com/photo-1521572163474-6864f9cf17ab?auto=format&fit=crop&w=900&q=85','BEST SELLER'),
('10000000-0000-4000-8000-000000000002','NO SKIPS HOODIE','Hoodies','Music',88,18,array['Vintage charcoal'],array['S','M','L','XL','XXL'],'Premium heavyweight fleece and easy oversized fit made for all-night listening.','https://images.unsplash.com/photo-1556821840-3a63f95609a7?auto=format&fit=crop&w=900&q=85','NEW DROP'),
('10000000-0000-4000-8000-000000000003','PLAYER TWO CAP','Caps','Gaming',36,30,array['Black / electric'],array['OS'],'Structured six-panel cap with embroidered mark and adjustable back strap.','https://images.unsplash.com/photo-1588850561407-ed78c282e89b?auto=format&fit=crop&w=900&q=85',''),
('10000000-0000-4000-8000-000000000004','GOOD ENERGY TEE','T-shirts','Lifestyle',44,22,array['Off white'],array['S','M','L','XL','XXL'],'Soft washed cotton, oversized street fit, and bold back print.','https://images.unsplash.com/photo-1503342217505-b0a15ec3261c?auto=format&fit=crop&w=900&q=85','JUST IN'),
('10000000-0000-4000-8000-000000000005','FREQ. CHECK JERSEY','T-shirts','Music',72,12,array['Black / purple'],array['S','M','L','XL'],'Breathable mesh inspired by the lights and noise of the front row.','https://images.unsplash.com/photo-1576566588028-4147f3842f27?auto=format&fit=crop&w=900&q=85','LIMITED'),
('10000000-0000-4000-8000-000000000006','RESPAWN ZIP HOODIE','Hoodies','Gaming',96,14,array['Midnight black'],array['S','M','L','XL','XXL'],'Substantial zip hoodie with a generous hood, deep pockets, and sleeve detailing.','https://images.unsplash.com/photo-1556821840-3a63f95609a7?auto=format&fit=crop&w=900&q=85',''),
('10000000-0000-4000-8000-000000000007','HB LOGO SOCKS','Accessories','Lifestyle',18,40,array['White / black'],array['OS'],'Cushioned crew socks with ribbed support and woven HOOD BUOYZ branding.','https://images.unsplash.com/photo-1582966772680-860e372bb558?auto=format&fit=crop&w=900&q=85','2-PACK'),
('10000000-0000-4000-8000-000000000008','AFTER HOURS BEANIE','Caps','Music',34,20,array['Black'],array['OS'],'Rib-knit beanie with a fold cuff and tonal embroidered HB mark.','https://images.unsplash.com/photo-1576871337622-98d48d1cf531?auto=format&fit=crop&w=900&q=85','')
on conflict(id) do nothing;
