

WITH bounds AS (
    SELECT last_watermark - interval '1 day' AS lo,   -- перекрытие на поздние коммиты
           now()                             AS hi
    FROM mart.etl_load_log
    WHERE target_table = 'mart.patient_order_map'
)

INSERT INTO mart.patient_order_map (order_id, patient_pseudo_id)
SELECT
    unnest(dp.order_ids) AS order_id,
    dp.patient_pseudo_id
FROM mart.dim_patient dp;
WHERE dp.created_at > (SELECT lo FROM bounds) AND dp.created_at <= (SELECT hi FROM bounds)
 
CREATE INDEX IF NOT EXISTS idx_patient_order_map_pseudo ON mart.patient_order_map (patient_pseudo_id);
 

 