CREATE TABLE IF NOT EXISTS mart.etl_load_log (
    target_table   text PRIMARY KEY,
    last_watermark timestamp NOT NULL,
    updated_at     timestamp NOT NULL DEFAULT now()
);

-- Стартовые значения: с какой даты начинать первую загрузку.
-- ДО первого запуска выставьте дату, начиная с которой нужны данные (или оставьте 2000-01-01 для полной загрузки).
INSERT INTO mart.etl_load_log (target_table, last_watermark) VALUES
    ('dim_patient',             '2000-01-01'),
    ('patient_order_map',       '2000-01-01'),
    ('fact_measurement_raw',    '2000-01-01'),
    ('fact_cbc_case',           '2000-01-01'),
    ('fact_patient_history',    '2000-01-01')
ON CONFLICT (target_table) DO NOTHING;
