"""Учебный DAG №1: проверка, что Airflow видит БД Genesis и схему mart.
Запускается вручную (schedule=None). Если он позеленел — окружение настроено верно."""
from datetime import datetime

from airflow.sdk import DAG
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator

with DAG(
    dag_id="check_genesis_connection",
    start_date=datetime(2026, 1, 1),
    schedule=None,
    catchup=False,
    tags=["setup"],
) as dag:
    ping = SQLExecuteQueryOperator(
        task_id="ping",
        conn_id="genesis_db",
        sql="SELECT now(), current_database(), current_user;",
    )

    mart_exists = SQLExecuteQueryOperator(
        task_id="mart_schema_exists",
        conn_id="genesis_db",
        sql="""
            SELECT table_name
            FROM information_schema.tables
            WHERE table_schema = 'mart'
            ORDER BY table_name;
        """,
    )

    ping >> mart_exists
