BEGIN;

WITH bounds AS (
    SELECT last_watermark - interval '1 day' AS lo,
           now()                             AS hi
    FROM mart.etl_load_log
    WHERE target_table = 'mart.patient_order_map'
),
pairs AS (
    -- один заказ → один пациент; при конфликте берём пациента, обновлённого последним
    SELECT DISTINCT ON (o.order_id)
           o.order_id,
           dp.patient_pseudo_id
    FROM mart.dim_patient dp
    CROSS JOIN bounds b
    CROSS JOIN LATERAL unnest(dp.order_ids) AS o(order_id)
    WHERE dp.updated_at >  b.lo
      AND dp.updated_at <= b.hi
    ORDER BY o.order_id, dp.updated_at DESC
)
INSERT INTO mart.patient_order_map AS m (order_id, patient_pseudo_id)
SELECT order_id, patient_pseudo_id
FROM pairs
ON CONFLICT (order_id) DO UPDATE
SET patient_pseudo_id = EXCLUDED.patient_pseudo_id
WHERE m.patient_pseudo_id IS DISTINCT FROM EXCLUDED.patient_pseudo_id;

UPDATE mart.etl_load_log
SET last_watermark = now(),
    updated_at     = now()
WHERE target_table = 'mart.patient_order_map';

COMMIT;