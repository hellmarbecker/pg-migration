-- Sample e-commerce dataset for the migration source.
-- Expects psql variables: n_customers, n_products, n_orders.
-- Re-runnable: drops and recreates the "shop" schema.
-- Covers a mix of types (enum, uuid, numeric, jsonb, arrays, timestamptz)
-- so the migration exercises more than plain text/int columns, plus a
-- range-partitioned table and a trigger that writes into it.

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS shop CASCADE;
CREATE SCHEMA shop;
SET search_path = shop;

SELECT setseed(0.42);

CREATE TYPE order_status AS ENUM ('pending', 'paid', 'shipped', 'delivered', 'cancelled');

CREATE TABLE customers (
    customer_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    external_id  uuid        NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    email        text        NOT NULL UNIQUE,
    full_name    text        NOT NULL,
    country      char(2)     NOT NULL,
    is_active    boolean     NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL
);

CREATE TABLE products (
    product_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku          text          NOT NULL UNIQUE,
    name         text          NOT NULL,
    category     text          NOT NULL,
    price        numeric(10,2) NOT NULL CHECK (price >= 0),
    tags         text[]        NOT NULL DEFAULT '{}',
    attributes   jsonb         NOT NULL DEFAULT '{}'
);

CREATE TABLE orders (
    order_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  bigint       NOT NULL REFERENCES customers,
    status       order_status NOT NULL,
    ordered_at   timestamptz  NOT NULL,
    shipping     jsonb
);

CREATE TABLE order_items (
    order_id     bigint        NOT NULL REFERENCES orders ON DELETE CASCADE,
    line_no      smallint      NOT NULL,
    product_id   integer       NOT NULL REFERENCES products,
    quantity     integer       NOT NULL CHECK (quantity > 0),
    unit_price   numeric(10,2) NOT NULL,
    PRIMARY KEY (order_id, line_no)
);

INSERT INTO customers (email, full_name, country, is_active, created_at)
SELECT
    'customer' || g || '@example.com',
    (ARRAY['Anna','Ben','Clara','David','Eva','Felix','Greta','Hans','Ines','Jonas'])[1 + (random()*9)::int]
      || ' ' ||
    (ARRAY['Müller','Schmidt','Schneider','Fischer','Weber','Meyer','Wagner','Becker','Schulz','Hoffmann'])[1 + (random()*9)::int],
    (ARRAY['DE','AT','CH','NL','FR','GB','US','ES','IT','PL'])[1 + (random()*9)::int],
    random() > 0.05,
    now() - random() * interval '3 years'
FROM generate_series(1, :n_customers) g;

INSERT INTO products (sku, name, category, price, tags, attributes)
SELECT
    'SKU-' || lpad(g::text, 6, '0'),
    category || ' item ' || g,
    category,
    round((5 + random() * 495)::numeric, 2),
    ((ARRAY['{new}', '{sale}', '{new,eco}', '{}', '{bestseller}'])[1 + (random()*4)::int])::text[],
    jsonb_build_object(
        'weight_g', (50 + random() * 5000)::int,
        'color', (ARRAY['red','green','blue','black','white'])[1 + (random()*4)::int],
        'in_stock', random() > 0.1)
FROM generate_series(1, :n_products) g,
     LATERAL (SELECT (ARRAY['Books','Electronics','Garden','Kitchen','Sports','Toys'])[1 + g % 6] AS category) c;

INSERT INTO orders (customer_id, status, ordered_at, shipping)
SELECT
    1 + (random() * (:n_customers - 1))::bigint,
    (ARRAY['pending','paid','shipped','delivered','delivered','delivered','cancelled']::order_status[])[1 + (random()*6)::int],
    now() - random() * interval '2 years',
    CASE WHEN random() < 0.9 THEN jsonb_build_object(
        'carrier', (ARRAY['DHL','UPS','DPD','Hermes'])[1 + (random()*3)::int],
        'express', random() < 0.2)
    END
FROM generate_series(1, :n_orders) g;

INSERT INTO order_items (order_id, line_no, product_id, quantity, unit_price)
SELECT o.order_id, l.line_no, p.product_id, 1 + (random() * 4)::int, p.price
FROM orders o
CROSS JOIN LATERAL generate_series(1, 1 + (random() * 4)::int + (o.order_id * 0)::int) AS l(line_no)
JOIN LATERAL (
    SELECT 1 + (random() * (:n_products - 1))::int + (o.order_id * 0)::int + (l.line_no * 0) AS pid
) r ON true
JOIN products p ON p.product_id = r.pid;

-- Status history: range-partitioned by quarter on changed_at (requires PG17 for
-- the identity column on a partitioned table). The primary key must include the
-- partition key. A DEFAULT partition catches anything outside the ranges.
CREATE TABLE order_status_history (
    history_id   bigint GENERATED ALWAYS AS IDENTITY,
    order_id     bigint       NOT NULL REFERENCES orders ON DELETE CASCADE,
    old_status   order_status,
    new_status   order_status NOT NULL,
    changed_at   timestamptz  NOT NULL,
    PRIMARY KEY (history_id, changed_at)
) PARTITION BY RANGE (changed_at);

DO $$
DECLARE q timestamptz;
BEGIN
  FOR q IN SELECT generate_series(date_trunc('quarter', now() - interval '2 years'),
                                  date_trunc('quarter', now()), interval '3 months')
  LOOP
    EXECUTE format('CREATE TABLE %I PARTITION OF order_status_history FOR VALUES FROM (%L) TO (%L)',
                   'order_status_history_' || to_char(q, 'YYYY"q"Q'), q, q + interval '3 months');
  END LOOP;
END $$;
CREATE TABLE order_status_history_default PARTITION OF order_status_history DEFAULT;

-- Trigger: every status change on orders is logged into the partitioned table.
CREATE FUNCTION log_order_status_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO shop.order_status_history (order_id, old_status, new_status, changed_at)
  VALUES (NEW.order_id, OLD.status, NEW.status, now());
  RETURN NEW;
END $$;

CREATE TRIGGER orders_status_change
  AFTER UPDATE OF status ON orders
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION log_order_status_change();

-- History: one "created" entry per order (spread over all partitions), then
-- some status updates so the trigger writes rows (current quarter's partition).
INSERT INTO order_status_history (order_id, old_status, new_status, changed_at)
SELECT order_id, NULL, status, ordered_at FROM orders ORDER BY order_id;

UPDATE orders SET status = 'delivered' WHERE status = 'shipped' AND order_id % 10 = 0;

CREATE INDEX ON order_status_history (order_id);
CREATE INDEX ON orders (customer_id);
CREATE INDEX ON orders (ordered_at);
CREATE INDEX ON order_items (product_id);

ANALYZE;

SELECT 'customers' AS table_name, count(*) AS row_count FROM customers
UNION ALL SELECT 'products', count(*) FROM products
UNION ALL SELECT 'orders', count(*) FROM orders
UNION ALL SELECT 'order_items', count(*) FROM order_items
UNION ALL SELECT 'order_status_history', count(*) FROM order_status_history;
