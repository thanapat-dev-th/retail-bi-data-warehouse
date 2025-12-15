--STEP 0) Clear
BEGIN;
TRUNCATE TABLE sale_items, sales RESTART IDENTITY;
COMMIT;

--STEP 2) Regen SALES (Season + Trend + Cohort Repurchase)

--ปรับค่าตรง growth_2024, growth_2025, noise_sd ได้ตามใจ
BEGIN;

WITH params AS (
  SELECT
    DATE '2023-01-01' AS d0,
    DATE '2025-12-31' AS d1,

    0.12::numeric AS growth_2024,   -- 2024 โต +12% จาก 2023 (โดยเฉลี่ย)
    0.08::numeric AS growth_2025,   -- 2025 โต +8%  จาก 2024 (โดยเฉลี่ย)

    0.18::numeric AS noise_sd       -- ความแกว่งของเดือน (มากขึ้น = YoY สลับบวก/ลบมากขึ้น)
),
cust AS (
  SELECT
    p.customer_id,
    p.branch,
    -- first purchase กระจายตลอด 2023-2025
    (DATE '2023-01-01' + (random() * interval '1095 days'))::date AS first_purchase_date,
    CASE WHEN random() < 0.20 THEN 'HEAVY' ELSE 'NORMAL' END AS tier
  FROM branch_customer_pool p
),
orders AS (
  SELECT
    customer_id,
    branch,
    first_purchase_date,
    CASE
      WHEN tier = 'HEAVY'  THEN 12 + (random()*22)::int   -- 12..34
      ELSE 2 + (random()*6)::int                          -- 2..8
    END AS orders_cnt,
    tier
  FROM cust
),

-- 1) สร้าง “เดือน” 2023-2025 และสร้าง weight ต่อเดือนด้วย season + trend + noise
months AS (
  SELECT
    date_trunc('month', dd)::date AS ym
  FROM generate_series((SELECT d0 FROM params), (SELECT d1 FROM params), interval '1 day') dd
  GROUP BY 1
),
month_weight AS (
  SELECT
    m.ym,

    -- seasonality (ปรับได้ตามใจ)
    CASE EXTRACT(MONTH FROM m.ym)
      WHEN 1  THEN 0.98
      WHEN 2  THEN 1.00
      WHEN 3  THEN 1.02
      WHEN 4  THEN 0.95   -- เมษาแผ่ว
      WHEN 5  THEN 1.03
      WHEN 6  THEN 1.05
      WHEN 7  THEN 1.02
      WHEN 8  THEN 1.00
      WHEN 9  THEN 1.04
      WHEN 10 THEN 1.08
      WHEN 11 THEN 1.12
      WHEN 12 THEN 1.18   -- Q4 พีค
      ELSE 1.00
    END::numeric AS season,

    -- trend: ทำให้ 2024 > 2023 และ 2025 > 2024
    CASE EXTRACT(YEAR FROM m.ym)
      WHEN 2023 THEN 1.00
      WHEN 2024 THEN 1.00 + (SELECT growth_2024 FROM params)
      WHEN 2025 THEN (1.00 + (SELECT growth_2024 FROM params)) * (1.00 + (SELECT growth_2025 FROM params))
      ELSE 1.00
    END::numeric AS trend,

    -- noise รายเดือน (lognormal-ish) ให้เดือนเด่น/ดับสลับกันเหมือนจริง
    EXP( ((random()*2 - 1) * (SELECT noise_sd FROM params)) )::numeric AS noise
  FROM months m
),
month_weight2 AS (
  SELECT
    ym,
    (season * trend * noise) AS w,
    SUM(season * trend * noise) OVER () AS w_total,
    SUM(season * trend * noise) OVER (ORDER BY ym) AS w_cum
  FROM month_weight
),

-- 2) สุ่มเลือก “เดือนขาย” แบบ roulette จาก month_weight2
pick_month AS (
  SELECT
    o.customer_id,
    o.branch,
    o.first_purchase_date,
    o.tier,
    g.idx AS order_no,
    -- random สำหรับเลือกเดือน
    random() AS r_pick,
    -- random สำหรับกระจายภายในเดือน
    random() AS r_day,
    random() AS r_hour
  FROM orders o
  CROSS JOIN LATERAL generate_series(1, o.orders_cnt) g(idx)
),
picked AS (
  SELECT
    pm.*,
    mw.ym
  FROM pick_month pm
  JOIN LATERAL (
    SELECT ym
    FROM month_weight2
    WHERE w_cum >= pm.r_pick * w_total
    ORDER BY ym
    LIMIT 1
  ) mw ON TRUE
),

-- 3) สร้าง sale_date ให้ “cohort สวย” แต่ไม่กองอยู่ต้นเดียว:
--    ใช้ mixture: 70% ซื้อใกล้ first purchase, 30% ซื้อแบบกระจายทั้งช่วง 0..360 วัน
gen AS (
  SELECT
    customer_id,
    branch,
    CASE
      WHEN random() < 0.70 THEN
        (first_purchase_date + ((random()^2) * interval '180 days'))::date
      ELSE
        (first_purchase_date + (random() * interval '360 days'))::date
    END AS base_date,
    ym,
    r_day,
    r_hour
  FROM picked
)

INSERT INTO sales (sale_date, branch, customer_id, sale_ts, created_at, updated_at)
SELECT
  -- บังคับให้ลงใน “เดือนที่สุ่มมา” เพื่อให้ season/trend มีผลจริง
  -- เอาวันจาก base_date มาชนกับ ym
  (ym + ((EXTRACT(DAY FROM base_date)-1) * interval '1 day'))::date
    -- กันวันล้นเดือน: ถ้าวันเกินจำนวนวันในเดือน ให้ปักวันสุดท้ายของเดือน
    - CASE
        WHEN (ym + ((EXTRACT(DAY FROM base_date)-1) * interval '1 day'))::date
             >= (ym + interval '1 month')::date
        THEN ((ym + ((EXTRACT(DAY FROM base_date)-1) * interval '1 day'))::date - ((ym + interval '1 month')::date) + 1)
        ELSE 0
      END * interval '1 day' AS sale_date,

  branch,
  customer_id,

  (
    (ym + ((LEAST(28, GREATEST(1, (r_day*28)::int)) - 1) * interval '1 day'))::timestamp
    + (r_hour * interval '23 hours')
  ) AS sale_ts,

  NOW(), NOW()
FROM gen
WHERE ym >= DATE '2023-01-01'
  AND ym <  DATE '2026-01-01';

COMMIT;

--STEP 3-4) prod_weight / cat_weight / subcat_weight / prod_bag

--ของคุณใช้ต่อได้เลย ✅
--แต่มี 2 ทิปเล็กๆ ให้ “สินค้าครองโลก” หายจริง:

--ทิป 1: อย่าให้ w_prod = 10 ทุกตัวแบบสุ่มอิสระ

--ตอนนี้คุณสุ่ม w_prod ต่อสินค้าแบบ independent ทำให้ “บาง subcat อาจบังเอิญได้ 10 เยอะ”
--ถ้าอยากสมจริงกว่า: ทำ weight แบบ “แจก TOP/MID/TAIL ต่อ subcat” (ผมทำให้ได้ในรอบหน้า)

--ทิป 2: bag size 4817 ได้ แต่ให้ทำ index เพิ่ม

CREATE INDEX IF NOT EXISTS ix_prod_bag_id ON prod_bag(bag_id);
ANALYZE prod_bag;


-- หลัง gen เสร็จ: SQL เช็คว่า YoY “สลับบวก/ลบ” แล้วไหม
WITH m AS (
  SELECT date_trunc('month', sale_date)::date ym,
         SUM(line_revenue) rev
  FROM public.fact_sales
  GROUP BY 1
),
y AS (
  SELECT ym, rev,
         LAG(rev, 12) OVER (ORDER BY ym) rev_ly,
         (rev - LAG(rev, 12) OVER (ORDER BY ym)) / NULLIF(LAG(rev, 12) OVER (ORDER BY ym),0) AS yoy
  FROM m
)
SELECT * FROM y ORDER BY ym;

--  Insert sale_items (เวอร์ชันแนะนำ)
BEGIN;

-- กันพลาด: ถุงต้องไม่ว่าง
DO $$
BEGIN
  IF (SELECT COUNT(*) FROM prod_bag) = 0 THEN
    RAISE EXCEPTION 'prod_bag is empty. Build prod_bag first.';
  END IF;
END $$;

TRUNCATE TABLE sale_items RESTART IDENTITY;

-- ช่วย planner
ANALYZE sales;
ANALYZE prod_bag;

WITH bag AS (
  SELECT COUNT(*)::bigint AS n FROM prod_bag
)
INSERT INTO sale_items (sale_id, product_id, quantity, cost_price, sale_price, created_at, updated_at)
SELECT
  s.sale_id,
  b.product_id,
  GREATEST(1, (1 + (random()*4))::int) AS quantity,
  ROUND((b.unit_cost  * (0.95 + random()*0.10))::numeric, 2)::double precision AS cost_price,
  ROUND((b.unit_price * (0.90 + random()*0.20))::numeric, 2)::double precision AS sale_price,
  NOW(), NOW()
FROM sales s
CROSS JOIN LATERAL generate_series(1, (1 + (random()*5))::int) l(line_no)
CROSS JOIN bag
JOIN prod_bag b
  ON b.bag_id =
     ( (hashtextextended(s.sale_id::text || '-' || l.line_no::text, 0) % bag.n) + 1 );

COMMIT;