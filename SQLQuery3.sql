DROP TABLE IF EXISTS dbo.product_pricing;
SELECT
  p.product_id,
  p.product_category_name,
  CASE
    WHEN p.product_category_name IN ('perfumaria','bebes','brinquedos') THEN 1.30
    WHEN p.product_category_name IN ('informatica_acessorios','telefonia') THEN 1.15
    WHEN p.product_category_name IN ('moveis_decoracao','cama_mesa_banho') THEN 1.25
    ELSE 1.20
  END AS markup_factor
INTO dbo.product_pricing
FROM dbo.products as p;


DROP TABLE IF EXISTS dbo.order_items_priced;
SELECT
  oic.*,
  CAST(oic.unit_price * pp.markup_factor AS decimal(10,2)) AS list_price
INTO dbo.order_items_priced
FROM dbo.order_items_clean as oic
JOIN dbo.product_pricing pp ON oic.product_id = pp.product_id;


WITH first_order AS (
  SELECT
    customer_id,
    MIN(order_purchase_timestamp) AS first_order_date
  FROM dbo.orders
  GROUP BY customer_id
)
SELECT * FROM first_order;


WITH order_size AS (SELECT order_id,SUM(TRY_CONVERT(int, quantity)) AS items_in_order
FROM dbo.order_items_priced
GROUP BY order_id)
SELECT * FROM order_size;


DROP TABLE IF EXISTS dbo.discounts;
WITH first_order AS (SELECT customer_id, MIN(order_purchase_timestamp) AS first_order_date
FROM dbo.orders
GROUP BY customer_id),
order_size AS (SELECT order_id, SUM(try_convert(int, quantity)) AS items_in_order
FROM dbo.order_items_priced
GROUP BY order_id),base AS (SELECT oic.order_item_sk,o.order_id,o.customer_id,o.order_purchase_timestamp,
oic.list_price,oic.unit_price,os.items_in_order,
CASE
WHEN o.order_purchase_timestamp = fo.first_order_date THEN 'WELCOME'
WHEN os.items_in_order >= 3 THEN 'BULK'
ELSE 'NONE'
END AS discount_type
FROM dbo.order_items_priced as oic
JOIN orders as o ON oic.order_id = o.order_id
JOIN first_order as fo ON o.customer_id = fo.customer_id
JOIN order_size as os ON o.order_id = os.order_id)
SELECT ROW_NUMBER() OVER (ORDER BY order_item_sk) AS discount_id,order_item_sk,discount_type,
CASE
WHEN discount_type = 'WELCOME' THEN 0.10
WHEN discount_type = 'BULK' THEN 0.07
ELSE 0.00
END AS discount_percent,
CAST(list_price *
CASE
WHEN discount_type = 'WELCOME' THEN 0.10
WHEN discount_type = 'BULK' THEN 0.07
ELSE 0.00
END AS decimal(10,2)) AS discount_amount
INTO dbo.discounts
FROM base
WHERE discount_type <> 'NONE';


DROP TABLE IF EXISTS dbo.refunds;
WITH base AS (SELECT oic.order_item_sk,oic.order_id,oic.product_id,oic.unit_price,p.product_category_name,
ABS(CHECKSUM(NEWID())) % 100 AS rand_0_99
FROM dbo.order_items_clean as oic
JOIN dbo.products p ON oic.product_id = p.product_id),
scored AS (SELECT *,(3+ CASE WHEN unit_price >= 200 THEN 4 ELSE 0 END + CASE WHEN product_category_name 
IN ('informatica_acessorios','telefonia','moda') 
THEN 3 ELSE 0 END) AS refund_risk_percent FROM base)
SELECT
ROW_NUMBER() OVER (ORDER BY order_item_sk) AS refund_id,order_item_sk,
CAST(unit_price * 1.00 AS decimal(10,2)) AS refund_amount,
CASE
WHEN product_category_name IN ('informatica_acessorios','telefonia') THEN 'defective_or_not_as_described'
WHEN product_category_name IN ('moda') THEN 'size_or_fit'
ELSE 'changed_mind'
END AS refund_reason,
GETDATE() AS refund_date
INTO dbo.refunds
FROM scored
WHERE rand_0_99 < refund_risk_percent;



DROP TABLE IF EXISTS dbo.discounts_one;
WITH ranked AS (
  SELECT
    d.*,
    ROW_NUMBER() OVER (
      PARTITION BY d.order_item_sk
      ORDER BY d.discount_amount DESC
    ) AS rn
  FROM dbo.discounts d
)
SELECT
  discount_id,
  order_item_sk,
  discount_type,
  discount_percent,
  discount_amount
INTO dbo.discounts_one
FROM ranked
WHERE rn = 1;

DROP TABLE IF EXISTS dbo.refunds_fixed;

SELECT
  r.refund_id,
  r.order_item_sk,
  CAST(oi.unit_price - COALESCE(d.discount_amount,0) AS decimal(10,2)) AS refund_amount,
  r.refund_reason,
  r.refund_date
INTO dbo.refunds_fixed
FROM dbo.refunds r
JOIN dbo.order_items_clean oi ON r.order_item_sk = oi.order_item_sk
LEFT JOIN dbo.discounts_one d ON r.order_item_sk = d.order_item_sk;


DROP VIEW IF EXISTS dbo.vw_net_revenue;
GO
CREATE VIEW dbo.vw_net_revenue AS
SELECT
  oi.order_item_sk,
  oi.order_id,
  oi.product_id,
  oi.unit_price,
  COALESCE(d.discount_amount,0) AS discount_amount,
  COALESCE(r.refund_amount,0) AS refund_amount,
  (oi.unit_price - COALESCE(d.discount_amount,0) - COALESCE(r.refund_amount,0)) AS net_revenue
FROM dbo.order_items_clean oi
LEFT JOIN dbo.discounts_one d ON oi.order_item_sk = d.order_item_sk
LEFT JOIN dbo.refunds_fixed r ON oi.order_item_sk = r.order_item_sk;
GO


DROP VIEW IF EXISTS dbo.vw_net_revenue;
GO
CREATE VIEW dbo.vw_net_revenue AS
SELECT
  oi.order_item_sk,
  oi.order_id,
  oi.product_id,
  CAST(oi.unit_price AS decimal(10,2)) AS unit_price,
  CAST(COALESCE(d.discount_amount,0) AS decimal(10,2)) AS discount_amount,
  CAST(COALESCE(r.refund_amount,0) AS decimal(10,2)) AS refund_amount,
  CAST(ROUND(
      CAST(oi.unit_price AS decimal(10,4))
    - CAST(COALESCE(d.discount_amount,0) AS decimal(10,4))
    - CAST(COALESCE(r.refund_amount,0) AS decimal(10,4))
  ,2) AS decimal(10,2)) AS net_revenue
FROM dbo.order_items_clean oi
LEFT JOIN dbo.discounts_one d ON oi.order_item_sk = d.order_item_sk
LEFT JOIN dbo.refunds_fixed r ON oi.order_item_sk = r.order_item_sk;
GO

DROP VIEW IF EXISTS dbo.vw_refunds_agg;
GO

CREATE VIEW dbo.vw_refunds_agg AS
SELECT
  order_item_sk,
  SUM(refund_amount) AS total_refund_amount
FROM dbo.refunds_fixed
GROUP BY order_item_sk;
GO

DROP VIEW IF EXISTS dbo.vw_net_revenue;
GO

CREATE VIEW dbo.vw_net_revenue AS
SELECT
  oi.order_item_sk,
  oi.order_id,
  oi.product_id,
  p.product_category_name,

  CAST(oi.unit_price AS decimal(10,2)) AS unit_price,
  CAST(COALESCE(d.discount_amount, 0) AS decimal(10,2)) AS discount_amount,
  CAST(COALESCE(r.total_refund_amount, 0) AS decimal(10,2)) AS refund_amount,

  CAST(ROUND(
      CAST(oi.unit_price AS decimal(10,4))
    - CAST(COALESCE(d.discount_amount,0) AS decimal(10,4))
    - CAST(COALESCE(r.total_refund_amount,0) AS decimal(10,4))
  ,2) AS decimal(10,2)) AS net_revenue

FROM dbo.order_items_clean oi
LEFT JOIN dbo.discounts_one d
  ON oi.order_item_sk = d.order_item_sk
LEFT JOIN dbo.vw_refunds_agg r
  ON oi.order_item_sk = r.order_item_sk
LEFT JOIN dbo.products p
  ON oi.product_id = p.product_id;
GO

DROP VIEW IF EXISTS dbo.vw_net_revenue_enriched;
GO

CREATE VIEW dbo.vw_net_revenue_enriched AS
SELECT
    nr.*,
    om.order_purchase_timestamp,
    om.geolocation_state
FROM dbo.vw_net_revenue nr
LEFT JOIN dbo.order_metadata om
    ON nr.order_id = om.order_id;
GO


CREATE OR ALTER VIEW dbo.vw_net_revenue_enriched AS
SELECT
    nr.*,
    om.order_purchase_timestamp,
    CAST(om.order_purchase_timestamp AS date) AS purchase_date,
    DATEFROMPARTS(YEAR(om.order_purchase_timestamp), MONTH(om.order_purchase_timestamp), 1) AS purchase_month,
    om.geolocation_state
FROM dbo.vw_net_revenue nr
LEFT JOIN dbo.order_metadata om
    ON nr.order_id = om.order_id;
GO

CREATE OR ALTER VIEW dbo.vw_leakage_by_state AS
SELECT
  geolocation_state,
  SUM(discount_amount + refund_amount) AS leakage_amount,
  SUM(net_revenue + discount_amount + refund_amount) AS gross_revenue,
  CASE
    WHEN SUM(net_revenue + discount_amount + refund_amount) = 0 THEN NULL
    ELSE SUM(discount_amount + refund_amount) * 1.0
         / SUM(net_revenue + discount_amount + refund_amount)
  END AS leakage_pct
FROM dbo.vw_net_revenue_enriched
GROUP BY geolocation_state;
GO