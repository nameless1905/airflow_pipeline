BEGIN;

WITH bounds AS (
    SELECT last_watermark - interval '1 day' AS lo,
           now()                             AS hi
    FROM mart.etl_load_log
    WHERE target_table = 'mart.fact_patient_history'          -- сверьте с меткой в etl_load_log
),
changed AS (                                             -- 1) кейсы, новые или изменённые шагом 04
    SELECT fc.case_id, fc.patient_pseudo_id, fc.collected_at
    FROM mart.fact_cbc_case fc
    CROSS JOIN bounds b
    WHERE fc.updated_at >  b.lo
      AND fc.updated_at <= b.hi
),
affected AS (                                            -- 2) они сами + все более поздние кейсы тех же пациентов
    SELECT case_id FROM changed
    UNION
    SELECT later.case_id
    FROM changed ch
    JOIN mart.fact_cbc_case later
      ON later.patient_pseudo_id = ch.patient_pseudo_id
     AND later.collected_at      > ch.collected_at
)
INSERT INTO mart.fact_patient_history_2026 AS h (case_id, historical_results, delta_check, updated_at)
SELECT
    fc.case_id,
    hist.historical_results,
    (
        SELECT jsonb_object_agg(key || '_delta_pct', delta_pct)
        FROM (
            SELECT
                key,
                ROUND(
                    ((fc.indices_json        -> key ->> 'value')::numeric
                   - (hist.last_indices_json -> key ->> 'value')::numeric)
                    / NULLIF((hist.last_indices_json -> key ->> 'value')::numeric, 0) * 100,
                    1
                ) AS delta_pct
            FROM jsonb_object_keys(fc.indices_json) AS key
            WHERE hist.last_indices_json ? key
              AND (fc.indices_json        -> key ->> 'value') ~ '^-?\d+(\.\d+)?$'
              AND (hist.last_indices_json -> key ->> 'value') ~ '^-?\d+(\.\d+)?$'
        ) deltas
    ) AS delta_check,
    now()
FROM affected a
JOIN mart.fact_cbc_case fc ON fc.case_id = a.case_id
CROSS JOIN LATERAL (
    SELECT
        jsonb_agg(
            jsonb_build_object('collected_at', t.collected_at, 'indices', t.indices_json)
            ORDER BY t.collected_at DESC
        )                                                           AS historical_results,
        (array_agg(t.indices_json ORDER BY t.collected_at DESC))[1] AS last_indices_json
    FROM (
        SELECT prev.collected_at, prev.indices_json
        FROM mart.fact_cbc_case prev
        WHERE prev.patient_pseudo_id = fc.patient_pseudo_id
          AND prev.collected_at      < fc.collected_at
        ORDER BY prev.collected_at DESC
        LIMIT 5
    ) t
) hist
ON CONFLICT (case_id) DO UPDATE
SET historical_results = EXCLUDED.historical_results,
    delta_check        = EXCLUDED.delta_check,
    updated_at         = now()
WHERE (h.historical_results, h.delta_check)
      IS DISTINCT FROM
      (EXCLUDED.historical_results, EXCLUDED.delta_check);

UPDATE mart.etl_load_log
SET last_watermark = now(),
    updated_at     = now()
WHERE target_table = 'mart.fact_patient_history';

COMMIT;