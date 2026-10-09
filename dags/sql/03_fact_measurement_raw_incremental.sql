
BEGIN;

WITH bounds AS (
    SELECT last_watermark - interval '1 day' AS lo,   -- перекрытие на поздние коммиты
           now()                             AS hi
    FROM mart.etl_load_log
    WHERE target_table = 'mart.fact_measurement_raw'
)


INSERT INTO mart.fact_measurement_raw  AS f(
    measurecontext_id, orderline_id, order_id, patient_pseudo_id,
    measureparameter_id,  assay_id , assay_name, assay_standardcode, parametr_name,value, unit,ref_min, ref_max, flag,           -- 'L'/'H'/NULL, из lessflag/moreflag
    resultrefcharstatus_raw,       
    was_entered_manually ,
    
    method_id  ,
    method_name  ,
    analyser_id    ,
    analyser_name ,
    collected_at
    
)
SELECT
    mc.id,
    ol.id,
    
    o.id,
    pat.patient_pseudo_id,
    mc.measureparameter_id,
    a.id,
    a.name,
    a.standardcode,

    dmp.name,
    
    mc.numericvalue,
    munit.name,
    mc.normalminvalue,
    mc.normalmaxvalue,
    CASE
        WHEN mc.lessflag = true THEN 'L'
        WHEN mc.moreflag = true THEN 'H'
        ELSE NULL
    END AS flag,
    mc.resultrefcharstatus,
    mc.wasenteredmanually,
   
    mc.method_id,
    mth.name,
    mth.analyser_id,
    an.name,  -- TODO: связать конкретный лот (reagentlots), а не только reagent_id — нужна доп. логика выбора активного лота на дату
    coalesce(s.samplingtimestamp, ms.samplingtimestamp,
             s.creationtimestamp, o.registrationtimestamp)
FROM public.measurecontext mc
JOIN public.orderline ol       ON ol.id = mc.measureorderline_id

JOIN public.orders o             ON o.id = ol.order_id
left join mart.patient_order_map pat  on pat.order_id = o.id

JOIN public.assay a                ON a.id = ol.assay_id
LEFT JOIN public.measureparameter dmp ON dmp.id = mc.measureparameter_id
LEFT JOIN public.measuringunits munit ON dmp.measuringunit_id = munit.id
LEFT JOIN  public.method mth ON mth.id = mc.method_id
left join public.analyser an on an.id = mth.analyser_id
WHERE mc.deleted IS NOT TRUE  

 AND coalesce(ol.techvalidated_at, ol.completiontimestamp) >  (SELECT lo FROM bounds)
  AND coalesce(ol.techvalidated_at, ol.completiontimestamp) <= (SELECT hi FROM bounds)
  
  ON CONFLICT (measurecontext_id) DO UPDATE
SET patient_pseudo_id       = EXCLUDED.patient_pseudo_id,
    value                   = EXCLUDED.value,
    unit                    = EXCLUDED.unit,
    ref_min                 = EXCLUDED.ref_min,
    ref_max                 = EXCLUDED.ref_max,
    flag                    = EXCLUDED.flag,
    resultrefcharstatus_raw = EXCLUDED.resultrefcharstatus_raw,
    was_entered_manually    = EXCLUDED.was_entered_manually,
    method_id               = EXCLUDED.method_id,
    method_name             = EXCLUDED.method_name,
    analyser_id             = EXCLUDED.analyser_id,
    analyser_name           = EXCLUDED.analyser_name,
    updated_at = now()
WHERE (f.patient_pseudo_id, f.value, f.flag, f.unit, f.ref_min, f.ref_max, f.method_id)
      IS DISTINCT FROM
      (EXCLUDED.patient_pseudo_id, EXCLUDED.value, EXCLUDED.flag, EXCLUDED.unit,
       EXCLUDED.ref_min, EXCLUDED.ref_max, EXCLUDED.method_id);   -- не переписываем неизменившееся


UPDATE mart.etl_load_log
SET last_watermark = now(),     -- то же значение, что hi: одна транзакция
    updated_at     = now()
WHERE target_table = 'mart.fact_measurement_raw';

 

 COMMIT;
