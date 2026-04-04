-- Лабораторная работа - Модуль 17

-- Подготовка: создание таблицы логов
CREATE TABLE IF NOT EXISTS error_log (
    log_id      SERIAL PRIMARY KEY,
    log_time    TIMESTAMP DEFAULT NOW(),
    severity    VARCHAR(20),
    source      VARCHAR(100),
    sqlstate    VARCHAR(5),
    message     TEXT,
    detail      TEXT,
    hint        TEXT,
    context     TEXT,
    username    VARCHAR(100) DEFAULT CURRENT_USER,
    parameters  JSONB
);

CREATE OR REPLACE FUNCTION log_error(
    p_severity VARCHAR, p_source VARCHAR,
    p_sqlstate VARCHAR DEFAULT NULL, p_message TEXT DEFAULT NULL,
    p_detail TEXT DEFAULT NULL, p_hint TEXT DEFAULT NULL,
    p_context TEXT DEFAULT NULL, p_parameters JSONB DEFAULT NULL
)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_log_id INT;
BEGIN
    INSERT INTO error_log (severity, source, sqlstate, message, detail, hint, context, parameters)
    VALUES (p_severity, p_source, p_sqlstate, p_message, p_detail, p_hint, p_context, p_parameters)
    RETURNING log_id INTO v_log_id;
    RETURN v_log_id;
END;
$$;

-- Задание 1. Безопасное деление
CREATE OR REPLACE FUNCTION safe_production_rate(p_tons NUMERIC, p_hours NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_tons IS NULL OR p_hours IS NULL THEN
        RETURN NULL;
    END IF;

    BEGIN
        RETURN p_tons / p_hours;
    EXCEPTION
        WHEN division_by_zero THEN
            RAISE WARNING 'safe_production_rate: деление на ноль (tons=%, hours=%)', p_tons, p_hours;
            RETURN 0;
    END;
END;
$$;

-- Тестирование
SELECT safe_production_rate(150, 8) AS test_normal;
SELECT safe_production_rate(150, 0) AS test_zero;
SELECT safe_production_rate(NULL, 8) AS test_null;

-- Применение в запросе
SELECT
    equipment_id,
    tons_mined,
    operating_hours,
    safe_production_rate(tons_mined, operating_hours) AS rate
FROM fact_production
WHERE date_id = 20250115
ORDER BY rate DESC
LIMIT 10;

-- Задание 2. Валидация данных телеметрии
CREATE OR REPLACE FUNCTION validate_sensor_reading(p_sensor_type VARCHAR, p_value NUMERIC)
RETURNS VARCHAR
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_min NUMERIC;
    v_max NUMERIC;
BEGIN
    CASE p_sensor_type
        WHEN 'Температура' THEN v_min := -40; v_max := 200;
        WHEN 'Давление'    THEN v_min := 0;   v_max := 500;
        WHEN 'Вибрация'    THEN v_min := 0;   v_max := 100;
        WHEN 'Скорость'    THEN v_min := 0;   v_max := 50;
        ELSE
            RAISE EXCEPTION 'Неизвестный тип датчика: %', p_sensor_type
                USING ERRCODE = 'S0001';
    END CASE;

    IF p_value < v_min OR p_value > v_max THEN
        RAISE EXCEPTION 'Значение % вне допустимого диапазона для типа "%"', p_value, p_sensor_type
            USING ERRCODE = 'S0002',
                  HINT = format('Допустимый диапазон: %s .. %s', v_min, v_max);
    END IF;

    RETURN 'OK';
END;
$$;

-- Тестирование
SELECT validate_sensor_reading('Температура', 25.5) AS temp_ok;
SELECT validate_sensor_reading('Давление', 350) AS pressure_ok;
SELECT validate_sensor_reading('Температура', -40) AS temp_min;
SELECT validate_sensor_reading('Вибрация', 100) AS vib_max;

-- Задание 3. Обработка ошибок при вставке
DO $$
DECLARE
    v_success_cnt INT := 0;
    v_error_cnt   INT := 0;
    v_log_id      INT;
    v_msg TEXT;
    v_state TEXT;
    v_ctx TEXT;
BEGIN
    RAISE NOTICE '=== Пакетная загрузка простоев ===';

    FOR i IN 1..10 LOOP
        BEGIN
            CASE i
                WHEN 3 THEN
                    -- FK violation: несуществующий equipment_id
                    INSERT INTO fact_equipment_downtime (
                        downtime_id, equipment_id, date_id, shift_id, duration_min, reason_id
                    )
                    VALUES (99000 + i, 999999, 20250115, 1, 60, 1);

                WHEN 5 THEN
                    -- NOT NULL violation: NULL в обязательном поле
                    INSERT INTO fact_equipment_downtime (
                        downtime_id, equipment_id, date_id, shift_id, duration_min, reason_id
                    )
                    VALUES (99000 + i, 1, NULL, 1, 30, 1);

                WHEN 7 THEN
                    -- Unique violation: дублирующийся PK
                    INSERT INTO fact_equipment_downtime (
                        downtime_id, equipment_id, date_id, shift_id, duration_min, reason_id
                    )
                    VALUES (1, 1, 20250115, 1, 45, 1);

                ELSE
                    -- Корректные записи
                    INSERT INTO fact_equipment_downtime (
                        downtime_id, equipment_id, date_id, shift_id, duration_min, reason_id
                    )
                    VALUES (99000 + i, (i % 9) + 1, 20250115, (i % 2) + 1, 30 + i * 5, (i % 3) + 1);
            END CASE;

            v_success_cnt := v_success_cnt + 1;

        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS
                v_msg   = MESSAGE_TEXT,
                v_state = RETURNED_SQLSTATE,
                v_ctx   = PG_EXCEPTION_CONTEXT;

            v_error_cnt := v_error_cnt + 1;

            v_log_id := log_error(
                'ERROR', 'batch_downtime_insert', v_state, v_msg,
                NULL, NULL, v_ctx,
                jsonb_build_object('row_index', i)
            );

            RAISE WARNING 'Строка %: ошибка (%). Лог ID: %', i, v_state, v_log_id;
        END;
    END LOOP;

    RAISE NOTICE '=== ИТОГО: успешно %, ошибок % ===', v_success_cnt, v_error_cnt;
END $$;

-- Задание 4. GET STACKED DIAGNOSTICS — детальный отчёт
CREATE OR REPLACE FUNCTION test_error_diagnostics(p_error_type INT)
RETURNS TABLE (field_name VARCHAR, field_value TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_message    TEXT;
    v_detail     TEXT;
    v_hint       TEXT;
    v_context    TEXT;
    v_sqlstate   TEXT;
    v_constraint TEXT;
    v_datatype   TEXT;
    v_table      TEXT;
    v_column     TEXT;
    v_schema     TEXT;
    v_x          INT;
BEGIN
    BEGIN
        CASE p_error_type
            WHEN 1 THEN
                v_x := 1 / 0;

            WHEN 2 THEN
                INSERT INTO dim_mine (mine_id, mine_name, mine_code, region, max_depth_m, status)
                SELECT mine_id, mine_name, mine_code, region, max_depth_m, status
                FROM dim_mine LIMIT 1;

            WHEN 3 THEN
                INSERT INTO fact_production (production_id, equipment_id, date_id, shift_id, mine_id, tons_mined)
                VALUES (999999999, 999999, 20250115, 1, 1, 100);

            WHEN 4 THEN
                v_x := 'не число'::INT;

            WHEN 5 THEN
                RAISE EXCEPTION 'Пользовательская ошибка модуля 17'
                    USING ERRCODE = 'P0001',
                          DETAIL = 'Детали пользовательской ошибки',
                          HINT = 'Проверьте входные параметры';

            ELSE
                RAISE EXCEPTION 'Неизвестный тип ошибки: %', p_error_type;
        END CASE;

    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            v_message    = MESSAGE_TEXT,
            v_detail     = PG_EXCEPTION_DETAIL,
            v_hint       = PG_EXCEPTION_HINT,
            v_context    = PG_EXCEPTION_CONTEXT,
            v_sqlstate   = RETURNED_SQLSTATE,
            v_constraint = CONSTRAINT_NAME,
            v_datatype   = PG_DATATYPE_NAME,
            v_table      = TABLE_NAME,
            v_column     = COLUMN_NAME,
            v_schema     = SCHEMA_NAME;

        field_name := 'RETURNED_SQLSTATE';   field_value := v_sqlstate;   RETURN NEXT;
        field_name := 'MESSAGE_TEXT';        field_value := v_message;    RETURN NEXT;
        field_name := 'PG_EXCEPTION_DETAIL'; field_value := v_detail;     RETURN NEXT;
        field_name := 'PG_EXCEPTION_HINT';   field_value := v_hint;       RETURN NEXT;
        field_name := 'PG_EXCEPTION_CONTEXT'; field_value := v_context;   RETURN NEXT;
        field_name := 'CONSTRAINT_NAME';     field_value := v_constraint; RETURN NEXT;
        field_name := 'PG_DATATYPE_NAME';    field_value := v_datatype;   RETURN NEXT;
        field_name := 'TABLE_NAME';          field_value := v_table;      RETURN NEXT;
        field_name := 'COLUMN_NAME';         field_value := v_column;     RETURN NEXT;
        field_name := 'SCHEMA_NAME';         field_value := v_schema;     RETURN NEXT;
    END;
END;
$$;

-- Тестирование
SELECT * FROM test_error_diagnostics(1);
SELECT * FROM test_error_diagnostics(2);
SELECT * FROM test_error_diagnostics(3);
SELECT * FROM test_error_diagnostics(4);
SELECT * FROM test_error_diagnostics(5);

-- Задание 5. Безопасный импорт с логированием
CREATE TABLE IF NOT EXISTS staging_lab_results (
    row_id       SERIAL,
    mine_name    TEXT,
    sample_date  TEXT,
    fe_content   TEXT,
    moisture     TEXT,
    status       VARCHAR(20) DEFAULT 'NEW',
    error_msg    TEXT
);

TRUNCATE staging_lab_results;

INSERT INTO staging_lab_results (mine_name, sample_date, fe_content, moisture) VALUES
    ('Шахта "Северная"', '2025-01-10', '62.5', '5.2'),
    ('Несуществующая',   '2025-01-11', '60.0', '4.0'),
    ('Шахта "Западная"', '32-01-2025', '58.0', '3.5'),
    ('Шахта "Южная"',    '2025-01-12', 'N/A', '4.1'),
    ('Шахта "Восточная"', '2025-01-13', '150', '2.0'),
    ('Шахта "Северная"', '2025-01-14', '61.2', '7.5'),
    ('Шахта "Центральная"', '2025-01-15', '59.8', '4.8'),
    ('Шахта "Западная"', '2025-01-16', '-10', '5.0'),
    ('Шахта "Восточная"', '2025-01-17', '63.0', 'invalid'),
    ('Шахта "Южная"',    '2025-01-18', '55.5', '3.3');

CREATE OR REPLACE FUNCTION process_lab_import()
RETURNS TABLE (total INT, valid INT, errors INT)
LANGUAGE plpgsql
AS $$
DECLARE
    rec          RECORD;
    v_total      INT := 0;
    v_valid      INT := 0;
    v_errors     INT := 0;
    v_mine_id    INT;
    v_date       DATE;
    v_fe         NUMERIC;
    v_moisture   NUMERIC;
BEGIN
    FOR rec IN
        SELECT * FROM staging_lab_results WHERE status = 'NEW' ORDER BY row_id
    LOOP
        v_total := v_total + 1;

        BEGIN
            -- Проверка шахты
            SELECT mine_id INTO v_mine_id
            FROM dim_mine
            WHERE mine_name = rec.mine_name;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Шахта "%" не найдена', rec.mine_name
                    USING ERRCODE = 'P0002';
            END IF;

            -- Преобразование даты
            BEGIN
                v_date := rec.sample_date::DATE;
            EXCEPTION WHEN OTHERS THEN
                RAISE EXCEPTION 'Некорректная дата: "%"', rec.sample_date
                    USING ERRCODE = 'P0003';
            END;

            -- Преобразование Fe
            BEGIN
                v_fe := rec.fe_content::NUMERIC;
            EXCEPTION WHEN OTHERS THEN
                RAISE EXCEPTION 'Некорректное значение Fe: "%"', rec.fe_content
                    USING ERRCODE = 'P0004';
            END;

            -- Диапазон Fe
            IF v_fe < 0 OR v_fe > 100 THEN
                RAISE EXCEPTION 'Fe = % вне диапазона 0-100%%', v_fe
                    USING ERRCODE = 'P0005';
            END IF;

            -- Преобразование влажности
            BEGIN
                v_moisture := rec.moisture::NUMERIC;
            EXCEPTION WHEN OTHERS THEN
                RAISE EXCEPTION 'Некорректное значение влажности: "%"', rec.moisture
                    USING ERRCODE = 'P0006';
            END;

            -- Успех
            UPDATE staging_lab_results
            SET status = 'VALID', error_msg = NULL
            WHERE row_id = rec.row_id;

            v_valid := v_valid + 1;

        EXCEPTION WHEN OTHERS THEN
            v_errors := v_errors + 1;

            UPDATE staging_lab_results
            SET status = 'ERROR', error_msg = SQLERRM
            WHERE row_id = rec.row_id;

            PERFORM log_error(
                'ERROR', 'process_lab_import',
                SQLSTATE, SQLERRM,
                NULL, NULL, NULL,
                jsonb_build_object('row_id', rec.row_id, 'mine_name', rec.mine_name)
            );
        END;
    END LOOP;

    total := v_total;
    valid := v_valid;
    errors := v_errors;
    RETURN NEXT;
END;
$$;

-- Тестирование
SELECT * FROM process_lab_import();
SELECT row_id, mine_name, sample_date, fe_content, moisture, status, error_msg
FROM staging_lab_results ORDER BY row_id;
SELECT * FROM error_log WHERE source = 'process_lab_import' ORDER BY log_id DESC LIMIT 10;

-- Задание 6. Комплексная функция с иерархией обработки ошибок
CREATE TABLE IF NOT EXISTS daily_kpi (
    kpi_id         SERIAL PRIMARY KEY,
    mine_id        INT,
    date_id        INT,
    tons_mined     NUMERIC(12,2),
    oee_percent    NUMERIC(5,2),
    downtime_hours NUMERIC(10,2),
    quality_score  NUMERIC(5,2),
    status         VARCHAR(20),
    error_detail   TEXT,
    calculated_at  TIMESTAMP DEFAULT NOW(),
    UNIQUE (mine_id, date_id)
);

CREATE OR REPLACE FUNCTION recalculate_daily_kpi(p_date_id INT)
RETURNS TABLE (mines_processed INT, mines_ok INT, mines_error INT)
LANGUAGE plpgsql
AS $$
DECLARE
    rec              RECORD;
    v_processed      INT := 0;
    v_ok             INT := 0;
    v_errors         INT := 0;
    v_tons           NUMERIC;
    v_oee            NUMERIC;
    v_downtime_hours NUMERIC;
    v_quality        NUMERIC;
    v_planned_hours  NUMERIC := 24;
    v_err_msg        TEXT;
    v_message        TEXT;
    v_context        TEXT;
    v_sqlstate       TEXT;
BEGIN
    RAISE NOTICE '=== Пересчет KPI за дату % ===', p_date_id;

    FOR rec IN SELECT mine_id, mine_name FROM dim_mine LOOP
        v_processed := v_processed + 1;

        BEGIN
            -- Общая добыча
            SELECT COALESCE(SUM(tons_mined), 0)
            INTO v_tons
            FROM fact_production
            WHERE date_id = p_date_id AND mine_id = rec.mine_id;

            -- OEE
            SELECT ROUND(COALESCE(SUM(operating_hours), 0) / v_planned_hours * 100, 2)
            INTO v_oee
            FROM fact_production
            WHERE date_id = p_date_id AND mine_id = rec.mine_id;

            -- Часы простоев
            SELECT COALESCE(SUM(duration_min) / 60.0, 0)
            INTO v_downtime_hours
            FROM fact_equipment_downtime
            WHERE date_id = p_date_id AND mine_id = rec.mine_id;

            -- Среднее качество Fe
            SELECT ROUND(COALESCE(AVG(fe_content), 0), 2)
            INTO v_quality
            FROM fact_ore_quality
            WHERE date_id = p_date_id AND mine_id = rec.mine_id;

            -- UPSERT
            INSERT INTO daily_kpi (mine_id, date_id, tons_mined, oee_percent, downtime_hours, quality_score, status, error_detail)
            VALUES (rec.mine_id, p_date_id, v_tons, v_oee, v_downtime_hours, v_quality, 'OK', NULL)
            ON CONFLICT (mine_id, date_id) DO UPDATE SET
                tons_mined = EXCLUDED.tons_mined,
                oee_percent = EXCLUDED.oee_percent,
                downtime_hours = EXCLUDED.downtime_hours,
                quality_score = EXCLUDED.quality_score,
                status = 'OK',
                error_detail = NULL,
                calculated_at = NOW();

            v_ok := v_ok + 1;

        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS
                v_message  = MESSAGE_TEXT,
                v_context  = PG_EXCEPTION_CONTEXT,
                v_sqlstate = RETURNED_SQLSTATE;

            v_err_msg := v_message;
            v_errors := v_errors + 1;

            INSERT INTO daily_kpi (mine_id, date_id, status, error_detail)
            VALUES (rec.mine_id, p_date_id, 'ERROR', v_err_msg)
            ON CONFLICT (mine_id, date_id) DO UPDATE SET
                status = 'ERROR',
                error_detail = EXCLUDED.error_detail,
                calculated_at = NOW();

            PERFORM log_error(
                'ERROR', 'recalculate_daily_kpi',
                v_sqlstate, v_message,
                NULL, NULL, v_context,
                jsonb_build_object('mine_id', rec.mine_id, 'date_id', p_date_id)
            );

            RAISE WARNING 'Ошибка для шахты "%" (ID=%): %', rec.mine_name, rec.mine_id, v_err_msg;
        END;
    END LOOP;

    mines_processed := v_processed;
    mines_ok := v_ok;
    mines_error := v_errors;
    RETURN NEXT;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS
        v_message  = MESSAGE_TEXT,
        v_context  = PG_EXCEPTION_CONTEXT,
        v_sqlstate = RETURNED_SQLSTATE;

    PERFORM log_error(
        'CRITICAL', 'recalculate_daily_kpi',
        v_sqlstate, v_message,
        NULL, NULL, v_context,
        jsonb_build_object('date_id', p_date_id)
    );

    RAISE EXCEPTION 'Критическая ошибка в recalculate_daily_kpi: %', v_message;
END;
$$;

-- Тестирование
SELECT * FROM recalculate_daily_kpi(20250115);
SELECT * FROM daily_kpi WHERE date_id = 20250115 ORDER BY mine_id;

-- Очистка тестовых объектов после лабораторной работы

DROP FUNCTION IF EXISTS safe_production_rate(NUMERIC, NUMERIC);
DROP FUNCTION IF EXISTS validate_sensor_reading(VARCHAR, NUMERIC);
DROP FUNCTION IF EXISTS test_error_diagnostics(INT);
DROP FUNCTION IF EXISTS process_lab_import();
DROP FUNCTION IF EXISTS recalculate_daily_kpi(INT);
DROP FUNCTION IF EXISTS log_error(VARCHAR, VARCHAR, VARCHAR, TEXT, TEXT, TEXT, TEXT, JSONB);

DROP TABLE IF EXISTS staging_lab_results;
DROP TABLE IF EXISTS daily_kpi;
DROP TABLE IF EXISTS error_log;
