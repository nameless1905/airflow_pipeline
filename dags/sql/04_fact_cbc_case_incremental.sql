
BEGIN;

WITH bounds AS (
    SELECT last_watermark - interval '1 day' AS lo,   -- перекрытие на поздние коммиты
           now()                             AS hi
    FROM mart.etl_load_log
    WHERE target_table = 'mart.fact_cbc_case'
),
touched AS (                                             -- 1) какие строки заказа изменились
    SELECT DISTINCT fr.orderline_id
    FROM mart.fact_measurement_raw fr
    CROSS JOIN bounds b
    WHERE fr.updated_at >  b.lo
      AND fr.updated_at <= b.hi
),
agg AS (                                                 -- 2) собираем каждую ЦЕЛИКОМ
    SELECT
        fr.orderline_id,
        fr.order_id,
        fr.patient_pseudo_id,
        fr.collected_at,
        fr.assay_name,
        fr.assay_standardcode,
        
        jsonb_object_agg(
            fr.parametr_name,
            jsonb_build_object(
                'value',     fr.value,
                'unit',      fr.unit,
                'method',    fr.method_name,
                'analyzer',  fr.analyser_name,
                'ref_range', jsonb_build_array(fr.ref_min, fr.ref_max),
                'flag',      fr.flag
            )
        ) AS indices_json
    FROM mart.fact_measurement_raw fr
    JOIN touched t USING (orderline_id)                  -- все измерения изменившихся строк
    WHERE fr.parametr_name IS NOT NULL
      
    GROUP BY fr.orderline_id, fr.order_id, fr.patient_pseudo_id, fr.collected_at,
             fr.assay_name, fr.assay_standardcode
)
INSERT INTO mart.fact_cbc_case AS c (
    case_id, order_id, orderline_id, patient_pseudo_id, collected_at,
    age_years, sex, assay_name, assay_standardcode,
     indices_json
)
SELECT
    a.orderline_id,                                      -- case_id = orderline_id
    a.order_id,
    a.orderline_id,
    a.patient_pseudo_id,
    a.collected_at,
    CASE
        WHEN dp.birthdate IS NULL OR a.collected_at IS NULL THEN NULL
        WHEN date_part('year', age(a.collected_at, dp.birthdate)) BETWEEN 0 AND 120
            THEN date_part('year', age(a.collected_at, dp.birthdate))::int
    END,
    dp.sex_normalized,
   
    a.assay_name,
    a.assay_standardcode,
    
    a.indices_json
FROM agg a
LEFT JOIN mart.dim_patient dp ON dp.patient_pseudo_id = a.patient_pseudo_id
ON CONFLICT (orderline_id) DO UPDATE
SET patient_pseudo_id = EXCLUDED.patient_pseudo_id,
    collected_at      = EXCLUDED.collected_at,
    age_years         = EXCLUDED.age_years,
    sex               = EXCLUDED.sex,
    
    
    indices_json      = EXCLUDED.indices_json,
    updated_at = now()
WHERE (c.patient_pseudo_id, c.collected_at, c.age_years, c.sex,
        c.indices_json)
      IS DISTINCT FROM
      (EXCLUDED.patient_pseudo_id, EXCLUDED.collected_at, EXCLUDED.age_years, EXCLUDED.sex,
       EXCLUDED.indices_json);


    UPDATE mart.etl_load_log
SET last_watermark = now(),     -- то же значение, что hi: одна транзакция
    updated_at     = now()
WHERE target_table = 'mart.fact_cbc_case';

 

 COMMIT;

    