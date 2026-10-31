# HOOD BUOYZ storefront

The existing storefront is served from `outputs/`; this project adds a small Node server, an allowlisted admin dashboard, and the Supabase schema used for the live catalog, guest checkout, order tracking, and product image uploads.

## Run locally

1. Install Node.js 20 or newer.
2. Copy `.env.example` to `.env` and set `SUPABASE_URL` and `SUPABASE_ANON_KEY` to the Supabase project URL and **publishable/anon** key. Never use a service-role or secret key in this app.
3. Run `npm start` from the project folder, then open `http://127.0.0.1:4173`. The admin page is at `http://127.0.0.1:4173/admin`.

Without Supabase settings, the storefront shows its original sample products in preview mode. New orders require a connected and initialized Supabase project.

## Initialize Supabase

1. Create a Supabase project.
2. In the project SQL Editor, run `supabase/schema.sql`. This creates the product/order schema, RLS policies, validated guest-order RPC, public product-image bucket, and eight sample products.
3. Copy the project's URL and publishable key into `.env`, restart the server.
4. In Supabase Authentication, create an administrator user manually. Keep public sign-ups disabled.
5. Copy that user's UUID from Authentication and run this owner-only SQL statement, replacing the value:

   ```sql
   insert into public.admin_users(user_id) values ('AUTH_USER_UUID');
   ```

6. Sign in at `/admin`. Only user IDs listed in `admin_users` pass the dashboard gate, and RLS independently protects catalog, orders, and image-management operations.

The browser receives only the project URL and publishable/anon key. Database access is controlled by RLS; the service-role key is neither needed nor supported here. Product images are publicly readable for the storefront and writable only by allowlisted administrators.

## Ordering and payments

Guests submit name, email, phone, and delivery address without creating an account. `submit_customer_order` validates products, sizes, colours, quantities, and current stock, calculates the total from database prices, decrements stock, and stores an order and item snapshots in one database transaction. Administrators can update fulfilment status in `/admin`.

No payment provider is integrated. The dashboard records order totals and fulfilment status only; payment must be arranged separately with the customer.

## Deployment

Deploy the Node server behind HTTPS and set `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `PORT` in the hosting provider's environment configuration. Apply `supabase/schema.sql` to the production project and provision administrator UUIDs manually. Do not commit `.env`.
