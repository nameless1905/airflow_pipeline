"""Скелет инкрементальной загрузки витрины mart.

Порядок шагов повторяет зависимости таблиц:
  dim_patient -> patient_order_map -> fact_measurement_raw -> fact_cbc_case -> fact_patient_history

Каждый шаг — отдельный SQL-файл в dags/sql/. Внутри каждого файла действует один и тот же паттерн:
  1) прочитать last_watermark из mart.etl_load_log для этой таблицы
  2) обработать только записи новее watermark (ON CONFLICT ... для идемпотентности)
  3) обновить watermark в mart.etl_load_log

Идемпотентность важна: если задача упала и Airflow запустил её повторно, дублей быть не должно.
"""
from datetime import datetime, timedelta

from airflow.sdk import DAG
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator

CONN_ID = "genesis_db"

default_args = {
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="mart_incremental",
    start_date=datetime(2026, 1, 1),
    schedule="@hourly",
    catchup=False,
    max_active_runs=1,  # два параллельных прогона по одному watermark не нужны
    default_args=default_args,
    template_searchpath=["/opt/airflow/dags/sql"],
    tags=["mart", "cbc"],
) as dag:
    init_log = SQLExecuteQueryOperator(
        task_id="init_etl_log",
        conn_id=CONN_ID,
        sql="00_init_etl_log.sql",
    )

    dim_patient = SQLExecuteQueryOperator(
        task_id="dim_patient",
        conn_id=CONN_ID,
        sql="01_dim_patient_incremental.sql",
    )

    patient_order_map = SQLExecuteQueryOperator(
        task_id="patient_order_map",
        conn_id=CONN_ID,
        sql="02_patient_order_map_incremental.sql",
    )

    fact_measurement_raw = SQLExecuteQueryOperator(
        task_id="fact_measurement_raw",
        conn_id=CONN_ID,
        sql="03_fact_measurement_raw_incremental.sql",
    )

    fact_cbc_case = SQLExecuteQueryOperator(
        task_id="fact_cbc_case",
        conn_id=CONN_ID,
        sql="04_fact_cbc_case_incremental.sql",
    )

    fact_patient_history = SQLExecuteQueryOperator(
        task_id="fact_patient_history",
        conn_id=CONN_ID,
        sql="05_fact_patient_history_incremental.sql",
    )

    (
        init_log
        >> dim_patient
        >> patient_order_map
        >> fact_measurement_raw
        >> fact_cbc_case
        >> fact_patient_history
    )
