BEGIN;  -- в Airflow не обязательно, но не мешает

WITH bounds AS (
    SELECT last_watermark - interval '1 day' AS lo,   -- перекрытие на поздние коммиты
           now()                             AS hi
    FROM mart.etl_load_log
    WHERE target_table = 'mart.dim_patient'
),
normalized_orders AS (
    SELECT
        o.id                                     AS order_id,
        lower(trim(o.firstname))                 AS fn,
        lower(trim(o.lastname))                  AS ln,
        lower(trim(coalesce(o.middlename, '')))  AS mn,
        o.birthdate::date                        AS bd,
        o.sex                                    AS sex_raw
    FROM public.orders o
    CROSS JOIN bounds b
    WHERE o.deleted = false
      AND o.firstname IS NOT NULL
      AND o.lastname  IS NOT NULL
      AND o.birthdate IS NOT NULL
      AND o.creationtimestamp >  b.lo
      AND o.creationtimestamp <= b.hi
),
grouped AS (
    SELECT
        fn, ln, mn, bd,
        mode() WITHIN GROUP (ORDER BY sex_raw)  AS sex_mode,
        array_agg(order_id ORDER BY order_id)   AS order_ids,
        count(*)                                AS orders_matched_count
    FROM normalized_orders
    GROUP BY fn, ln, mn, bd
)
INSERT INTO mart.dim_patient AS d (
    patient_pseudo_id, natural_key_hash, order_ids,
    birthdate, sex_normalized, orders_matched_count, needs_manual_review
)
SELECT
    'p_' || substr(encode(digest(
        fn || '|' || ln || '|' || mn || '|' || bd::text
        || (SELECT salt_value FROM mart.pseudonymization_config LIMIT 1),
        'sha256'), 'hex'), 1, 12)                                              AS patient_pseudo_id,
    encode(digest(fn || '|' || ln || '|' || mn || '|' || bd::text, 'sha256'), 'hex') AS natural_key_hash,
    order_ids,
    bd,
    sex_mode::text,          -- TODO: расшифровать через enum-справочник
    orders_matched_count,
    orders_matched_count > 15
FROM grouped
ON CONFLICT (natural_key_hash) DO UPDATE
SET order_ids = ARRAY(
        SELECT DISTINCT x
        FROM unnest(d.order_ids || EXCLUDED.order_ids) AS x
        ORDER BY x),
    orders_matched_count = cardinality(ARRAY(
        SELECT DISTINCT unnest(d.order_ids || EXCLUDED.order_ids))),
    needs_manual_review = cardinality(ARRAY(
        SELECT DISTINCT unnest(d.order_ids || EXCLUDED.order_ids))) > 15;
    -- patient_pseudo_id, birthdate, sex_normalized у существующего пациента не трогаем

UPDATE mart.etl_load_log
SET last_watermark = now(),     -- то же значение, что hi: одна транзакция
    updated_at     = now()
WHERE target_table = 'mart.dim_patient';

COMMIT;