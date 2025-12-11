
# Postgresql for simulation HomeDepo data
# 🏗️ PostgreSQL HomeDepo Demo Datamart
**Retail Data Warehouse Simulation for BI & Analytics**  

This repository contains a demo **retail datamart** for a Home-Improvement / HomePro-style store,  
designed for **Power BI, data analytics, inventory optimization, and automation experiments**.

---

## 📚 Table of Contents
- [Objective](#-objective)
- [Schema Overview](#-schema-overview)
- [Entity–Relationship Diagram (ERD)](#-entityrelationship-diagram-erd)
- [Data Generation Workflow](#-data-generation-workflow)
- [Example Analytics Queries](#-example-analytics-queries)
- [Use Cases](#-use-cases)
- [Roadmap](#-roadmap)
- [Author](#-author)

---

## 🎯 Objective
- Simulate a **realistic retail datamart** with customers, products, sales, and stock
- Generate **synthetic sales data** using 80/20 logic + customer segmentation
- Provide a clean **fact table** for BI tools (Power BI, etc.)
- Serve as a **portfolio-ready project** for data / BI / analytics roles

---

## 🗂️ Schema Overview

### 1. Dimension / Master Tables
- `customers`
- `districts`
- `products`
- `categories`
- `warehouses`
- `products_raw`
- `dim_customers`
- `dim_products`

### 2. Transaction / Fact Base Tables
- `sales`
- `sale_items`
- `stocks`
- `stocks_backup` (snapshot / backup)

### 3. Staging / Temporary
- `tmp_order_lines`

### 4. BI Layer
- `fact_sales` (VIEW)
- `vw_stock_speed` (VIEW: on-hand, stock speed, days of cover)

---

## 🧩 Entity–Relationship Diagram (ERD)

The diagram below summarizes the relationships between all core tables used in the demo datamart.

![HomeDepo Datamart ERD](HomeDepo_ERD.png)

Key highlights:
- `fact_sales` joins `sales` and `sale_items` for line-level analytics
- `vw_stock_speed` combines stock, cost, and last sale info for inventory analysis
- `dim_customers` and `dim_products` are cleaned, analytics-friendly dimensions

---

## ⚙️ Data Generation Workflow

### Step 1: Prepare Master Data
1. Import CSV files into:
   - `products_raw`
   - `customers`
   - `districts`
2. Randomly assign **margin (5–250%)** from `unit_cost` to generate `unit_price`:

```sql
UPDATE products_raw
SET unit_price = ROUND(
    (unit_cost * (1.05 + random() * (3.50 - 1.05)))::numeric,
    2
)
WHERE unit_cost IS NOT NULL;
```

3. Sync into `products`:

```sql
UPDATE products p
SET unit_cost  = r.unit_cost,
    unit_price = r.unit_price
FROM products_raw r
WHERE p.sku_id = r.sku_id;
```

### Step 2: Sales Simulation with 80/20 Logic

Core ideas:
- Product popularity segments: **TOP / MID / TAIL**
- Customer segments: **HEAVY / MEDIUM / LIGHT**
- Use `generate_series` and `CROSS JOIN LATERAL` to create realistic order patterns

Example: create `tmp_order_lines` with product and customer profiles, order plans,
and random sale dates across the year (see full SQL script in the project).

Then convert `tmp_order_lines` into `sale_items`:

```sql
INSERT INTO sale_items (sale_id, product_id, quantity, cost_price, sale_price)
SELECT
    t.sale_id,
    t.product_id,
    GREATEST(1, (t.quantity * t.spend_factor)::int) AS quantity,
    p.unit_cost,
    p.unit_price
FROM tmp_order_lines t
JOIN products p ON t.product_id = p.product_id;
```

### Step 3: BI Fact Table

```sql
CREATE OR REPLACE VIEW fact_sales AS
SELECT
    s.sale_id,
    s.sale_date,
    s.branch,
    s.customer_id,
    si.sale_item_id,
    si.product_id,
    si.quantity,
    si.sale_price * si.quantity  AS line_revenue,
    si.cost_price * si.quantity  AS line_cost,
    (si.sale_price - si.cost_price) * si.quantity AS line_profit
FROM sales s
JOIN sale_items si ON s.sale_id = si.sale_id;
```

`fact_sales` is the primary table used for Power BI dashboards.

---

## 📊 Example Analytics Queries

### Profit by Category

```sql
SELECT
    c.cat_name,
    SUM(fs.line_revenue) AS total_revenue,
    SUM(fs.line_cost)    AS total_cost,
    SUM(fs.line_profit)  AS total_profit,
    ROUND(
        SUM(fs.line_profit) / NULLIF(SUM(fs.line_revenue), 0),
        3
    ) AS profit_margin
FROM fact_sales fs
JOIN products   p ON fs.product_id = p.product_id
JOIN categories c ON p.category_id = c.category_id
GROUP BY c.cat_name
ORDER BY total_profit DESC;
```

### Top Products by Profit

```sql
SELECT
    p.product_name,
    SUM(fs.line_profit) AS total_profit
FROM fact_sales fs
JOIN products p ON fs.product_id = p.product_id
GROUP BY p.product_name
ORDER BY total_profit DESC
LIMIT 20;
```

### Inventory / Stock Speed (vw_stock_speed)

Example questions supported by `vw_stock_speed`:
- Days of cover by product / branch
- Slow-moving or no-sales SKUs
- Stock value by warehouse

---

## 🚀 Use Cases

This demo datamart can be used for:

- Data Analyst / BI **portfolio project**
- Power BI / Tableau dashboard demos
- Retail / inventory / margin analysis experiments
- n8n / Python automation workflows
- Teaching / learning SQL data modeling

---

## 🗺️ Roadmap

- ✅ Core datamart schema
- ✅ Synthetic sales generator (80/20 + segments)
- ✅ `fact_sales` and `vw_stock_speed` views
- ⏳ More advanced stock movement simulation
- ⏳ Reorder point & safety stock model
- ⏳ Power BI dashboard templates
- ⏳ n8n automation examples (ETL / alerts)

---

## 👤 Author

**Thana P.**  
Background: Network Engineering → Data / AI Automation  
Interests: Retail analytics, supply chain, BI, automation, and workflow orchestration.
