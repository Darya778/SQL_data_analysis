-- Лабораторная работа - Модуль 15

-- Задание 1. Скалярная функция - расчёт OEE
CREATE OR REPLACE FUNCTION calc_oee(
    p_operating_hours NUMERIC,
    p_planned_hours NUMERIC,
    p_actual_tons NUMERIC,
    p_target_tons NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_planned_hours = 0 OR p_target_tons = 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(
        (p_operating_hours / p_planned_hours) *
        (p_actual_tons / p_target_tons) * 100,
        1
    );
END;
$$;

-- Тестирование функции
SELECT calc_oee(10, 12, 80, 100) AS test1;
SELECT calc_oee(12, 12, 100, 100) AS test2;
SELECT calc_oee(8, 12, 0, 100) AS test3;

-- Использование в запросе
SELECT
    d.full_date,
    e.equipment_name,
    calc_oee(fp.operating_hours, 12, fp.tons_mined, 100) AS oee_pct
FROM fact_production fp
JOIN dim_equipment e ON fp.equipment_id = e.equipment_id
JOIN dim_date d ON fp.date_id = d.date_id
WHERE fp.date_id BETWEEN 20240101 AND 20240107
LIMIT 10;

-- Задание 2. Функция с условной логикой - классификация простоев
CREATE OR REPLACE FUNCTION classify_downtime(p_duration_min NUMERIC)
RETURNS VARCHAR
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    RETURN CASE
        WHEN p_duration_min < 15 THEN 'Микропростой'
        WHEN p_duration_min <= 60 THEN 'Краткий простой'
        WHEN p_duration_min <= 240 THEN 'Средний простой'
        WHEN p_duration_min <= 480 THEN 'Длительный простой'
        ELSE 'Критический простой'
    END;
END;
$$;

-- Применение функции к данным
WITH classified_data AS (
    SELECT
        classify_downtime(duration_min) AS category,
        duration_min
    FROM fact_equipment_downtime
    WHERE date_id BETWEEN 20240101 AND 20240131
)
SELECT
    category AS "Категория",
    COUNT(*) AS "Количество",
    ROUND(AVG(duration_min), 1) AS "Средняя длит. (мин)",
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) || '%' AS "Процент от общего"
FROM classified_data
GROUP BY category
ORDER BY
    CASE category
        WHEN 'Микропростой' THEN 1
        WHEN 'Краткий простой' THEN 2
        WHEN 'Средний простой' THEN 3
        WHEN 'Длительный простой' THEN 4
        ELSE 5
    END;

-- Задание 3. Табличная функция - детальный отчёт по оборудованию
CREATE OR REPLACE FUNCTION get_equipment_summary(
    p_equipment_id INT,
    p_date_from INT,
    p_date_to INT
)
RETURNS TABLE (
    report_date DATE,
    tons_mined NUMERIC,
    trips INT,
    operating_hours NUMERIC,
    fuel_liters NUMERIC,
    tons_per_hour NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT
        d.full_date,
        ROUND(SUM(fp.tons_mined), 2),
        SUM(fp.trips_count)::INT,
        ROUND(SUM(fp.operating_hours), 2),
        ROUND(SUM(fp.fuel_consumed_l), 2),
        ROUND(SUM(fp.tons_mined) / NULLIF(SUM(fp.operating_hours), 0), 2)
    FROM fact_production fp
    JOIN dim_date d ON fp.date_id = d.date_id
    WHERE fp.equipment_id = p_equipment_id
      AND fp.date_id BETWEEN p_date_from AND p_date_to
    GROUP BY d.full_date
    ORDER BY d.full_date;
END;
$$;

-- Тестирование
SELECT * FROM get_equipment_summary(1, 20240101, 20240131) LIMIT 10;

-- Использование с LATERAL JOIN
SELECT
    e.equipment_name,
    s.*
FROM dim_equipment e
CROSS JOIN LATERAL get_equipment_summary(e.equipment_id, 20240101, 20240131) s
WHERE e.mine_id = 1
ORDER BY e.equipment_name, s.report_date
LIMIT 20;

-- Задание 4. Функция с дефолтными параметрами - гибкий фильтр
CREATE OR REPLACE FUNCTION get_production_filtered(
    p_date_from INT,
    p_date_to INT,
    p_mine_id INT DEFAULT NULL,
    p_shift_id INT DEFAULT NULL,
    p_equipment_type_id INT DEFAULT NULL
)
RETURNS TABLE (
    mine_name VARCHAR,
    shift_name VARCHAR,
    equipment_type VARCHAR,
    total_tons NUMERIC,
    total_trips BIGINT,
    equip_count BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.mine_name,
        s.shift_name,
        et.type_name AS equipment_type,
        ROUND(SUM(fp.tons_mined), 2),
        SUM(fp.trips_count)::BIGINT,
        COUNT(DISTINCT fp.equipment_id)
    FROM fact_production fp
    JOIN dim_mine m ON fp.mine_id = m.mine_id
    JOIN dim_shift s ON fp.shift_id = s.shift_id
    JOIN dim_equipment e ON fp.equipment_id = e.equipment_id
    JOIN dim_equipment_type et ON e.equipment_type_id = et.equipment_type_id
    WHERE fp.date_id BETWEEN p_date_from AND p_date_to
      AND (p_mine_id IS NULL OR fp.mine_id = p_mine_id)
      AND (p_shift_id IS NULL OR fp.shift_id = p_shift_id)
      AND (p_equipment_type_id IS NULL OR e.equipment_type_id = p_equipment_type_id)
    GROUP BY m.mine_name, s.shift_name, et.type_name
    ORDER BY m.mine_name, s.shift_name;
END;
$$;

-- Тестирование вызовов
SELECT * FROM get_production_filtered(20240101, 20240131) LIMIT 10;
SELECT * FROM get_production_filtered(20240101, 20240131, p_mine_id := 1);
SELECT * FROM get_production_filtered(20240101, 20240131, 1, 1);

-- Задание 5. Процедура с транзакциями - архивация данных
CREATE TABLE IF NOT EXISTS archive_telemetry (
    LIKE fact_equipment_telemetry INCLUDING ALL
);

CREATE OR REPLACE PROCEDURE archive_old_telemetry(
    p_before_date_id INT,
    INOUT p_archived INT DEFAULT 0,
    INOUT p_deleted INT DEFAULT 0
)
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE '--- Начало архивации данных до даты % ---', p_before_date_id;

    -- Шаг 1: Копирование в архив
    INSERT INTO archive_telemetry
    SELECT * FROM fact_equipment_telemetry
    WHERE date_id < p_before_date_id;

    GET DIAGNOSTICS p_archived = ROW_COUNT;
    RAISE NOTICE 'Шаг 1 завершен: скопировано % записей.', p_archived;
    COMMIT;

    -- Шаг 2: Удаление из основной таблицы
    IF p_archived > 0 THEN
        DELETE FROM fact_equipment_telemetry
        WHERE date_id < p_before_date_id;

        GET DIAGNOSTICS p_deleted = ROW_COUNT;
        RAISE NOTICE 'Шаг 2 завершен: удалено % записей.', p_deleted;
        COMMIT;
    ELSE
        RAISE NOTICE 'Нет данных для удаления.';
    END IF;

    RAISE NOTICE '--- Архивация успешно завершена ---';
END;
$$;

-- Тестирование
CALL archive_old_telemetry(20240201, 0, 0);

SELECT COUNT(*) FROM archive_telemetry;
SELECT COUNT(*) FROM fact_equipment_telemetry WHERE date_id < 20240201;

-- Очистка тестовых данных
DELETE FROM archive_telemetry WHERE date_id < 20240201;

-- Задание 6. Динамический SQL - универсальный счётчик
CREATE OR REPLACE FUNCTION count_fact_records(
    p_table_name TEXT,
    p_date_from INT,
    p_date_to INT
)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result BIGINT;
    v_query TEXT;
BEGIN
    -- Валидация: только таблицы фактов
    IF p_table_name NOT LIKE 'fact_%' THEN
        RAISE EXCEPTION 'Доступ запрещен: Таблица % не является таблицей фактов (должна начинаться с fact_)', p_table_name;
    END IF;

    v_query := format('SELECT COUNT(*) FROM %I WHERE date_id BETWEEN $1 AND $2', p_table_name);

    EXECUTE v_query INTO v_result USING p_date_from, p_date_to;

    RETURN v_result;
END;
$$;

-- Тестирование
SELECT count_fact_records('fact_production', 20240101, 20240131) AS prod_count;
SELECT count_fact_records('fact_equipment_downtime', 20240101, 20240131) AS downtime_count;
-- SELECT count_fact_records('dim_mine', 20240101, 20240131); -- Ошибка!

-- Задание 7. Динамический SQL - построитель отчётов
CREATE OR REPLACE FUNCTION build_production_report(
    p_group_by TEXT,
    p_date_from INT,
    p_date_to INT,
    p_order_by TEXT DEFAULT 'total_tons DESC'
)
RETURNS TABLE (
    dimension_name VARCHAR,
    total_tons NUMERIC,
    total_trips BIGINT,
    avg_productivity NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_join TEXT;
    v_field TEXT;
    v_order TEXT;
    v_query TEXT;
BEGIN
    -- Определение JOIN и поля группировки
    CASE p_group_by
        WHEN 'mine' THEN
            v_join := 'JOIN dim_mine d ON fp.mine_id = d.mine_id';
            v_field := 'd.mine_name';
        WHEN 'shift' THEN
            v_join := 'JOIN dim_shift ds ON fp.shift_id = ds.shift_id';
            v_field := 'ds.shift_name';
        WHEN 'operator' THEN
            v_join := 'JOIN dim_operator d ON fp.operator_id = d.operator_id';
            v_field := 'd.last_name || '' '' || d.first_name';
        WHEN 'equipment' THEN
            v_join := 'JOIN dim_equipment d ON fp.equipment_id = d.equipment_id';
            v_field := 'd.equipment_name';
        WHEN 'equipment_type' THEN
            v_join := 'JOIN dim_equipment e ON fp.equipment_id = e.equipment_id 
                       JOIN dim_equipment_type d ON e.equipment_type_id = d.equipment_type_id';
            v_field := 'd.type_name';
        ELSE
            RAISE EXCEPTION 'Некорректное измерение: %. Допустимы: mine, shift, operator, equipment, equipment_type', p_group_by;
    END CASE;

    -- Определение сортировки
    v_order := CASE p_order_by
        WHEN 'total_tons DESC' THEN '2 DESC'
        WHEN 'total_tons ASC' THEN '2 ASC'
        WHEN 'dimension_name ASC' THEN '1 ASC'
        ELSE '2 DESC'
    END;

    -- Формирование запроса
    v_query := format(
        'SELECT
            %s::VARCHAR,
            ROUND(SUM(fp.tons_mined), 2),
            SUM(fp.trips_count)::BIGINT,
            ROUND(SUM(fp.tons_mined) / NULLIF(SUM(fp.operating_hours), 0), 2)
         FROM fact_production fp
         %s
         WHERE fp.date_id BETWEEN $1 AND $2
         GROUP BY 1
         ORDER BY %s',
        v_field, v_join, v_order
    );

    RETURN QUERY EXECUTE v_query USING p_date_from, p_date_to;
END;
$$;

-- Тестирование всех вариантов группировки
SELECT * FROM build_production_report('mine', 20240101, 20240131);
SELECT * FROM build_production_report('shift', 20240101, 20240131);
SELECT * FROM build_production_report('operator', 20240101, 20240131) LIMIT 10;
SELECT * FROM build_production_report('equipment', 20240101, 20240131) LIMIT 10;
SELECT * FROM build_production_report('equipment_type', 20240101, 20240131, 'dimension_name ASC');
-- SELECT * FROM build_production_report('wrong_field', 20240101, 20240131); -- Ошибка!

-- Задание 8. Комплексная процедура - ежедневная загрузка данных
CREATE TABLE IF NOT EXISTS staging_daily_production (
    date_id INT,
    equipment_id INT,
    shift_id INT,
    operator_id INT,
    tons_mined NUMERIC,
    trips_count INT,
    operating_hours NUMERIC,
    fuel_consumed_l NUMERIC,
    loaded_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS staging_rejected (
    LIKE staging_daily_production INCLUDING ALL,
    reject_reason TEXT,
    rejected_at TIMESTAMP DEFAULT NOW()
);

CREATE OR REPLACE PROCEDURE process_daily_production(
    p_date_id INT,
    OUT p_validated INT,
    OUT p_rejected INT,
    OUT p_loaded INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Шаг 1: Проверка наличия данных
    IF NOT EXISTS (SELECT 1 FROM staging_daily_production WHERE date_id = p_date_id) THEN
        RAISE EXCEPTION 'Данные за дату % отсутствуют в staging_daily_production', p_date_id;
    END IF;

    RAISE NOTICE 'Шаг 1: Данные найдены. Начинаю валидацию...';

    -- Шаг 2: Валидация данных
    INSERT INTO staging_rejected (
        date_id, equipment_id, shift_id, operator_id, tons_mined,
        trips_count, operating_hours, fuel_consumed_l, loaded_at, reject_reason
    )
    SELECT
        s.date_id, s.equipment_id, s.shift_id, s.operator_id, s.tons_mined,
        s.trips_count, s.operating_hours, s.fuel_consumed_l, s.loaded_at,
        CASE
            WHEN s.tons_mined < 0 THEN 'Отрицательная добыча'
            WHEN s.trips_count < 0 THEN 'Отрицательное кол-во рейсов'
            WHEN e.equipment_id IS NULL THEN 'Неизвестное оборудование (ID=' || s.equipment_id || ')'
            WHEN o.operator_id IS NULL THEN 'Неизвестный оператор (ID=' || s.operator_id || ')'
            ELSE 'Нарушение бизнес-логики'
        END
    FROM staging_daily_production s
    LEFT JOIN dim_equipment e ON s.equipment_id = e.equipment_id
    LEFT JOIN dim_operator o ON s.operator_id = o.operator_id
    WHERE s.date_id = p_date_id
      AND (s.tons_mined < 0
           OR s.trips_count < 0
           OR e.equipment_id IS NULL
           OR o.operator_id IS NULL);

    GET DIAGNOSTICS p_rejected = ROW_COUNT;

    -- Удаляем невалидные записи из staging
    DELETE FROM staging_daily_production
    WHERE date_id = p_date_id
      AND (tons_mined < 0
           OR trips_count < 0
           OR equipment_id NOT IN (SELECT equipment_id FROM dim_equipment)
           OR operator_id NOT IN (SELECT operator_id FROM dim_operator));

    RAISE NOTICE 'Шаг 2: Валидация завершена. Отбраковано: % зап.', p_rejected;
    COMMIT;

    -- Шаг 3: Удаление старых данных
    DELETE FROM fact_production WHERE date_id = p_date_id;
    RAISE NOTICE 'Шаг 3: Старые данные за % удалены из fact_production.', p_date_id;

    -- Шаг 4: Вставка валидных записей
    INSERT INTO fact_production (
        date_id, equipment_id, shift_id, operator_id,
        tons_mined, trips_count, operating_hours, fuel_consumed_l
    )
    SELECT
        date_id, equipment_id, shift_id, operator_id,
        tons_mined, trips_count, operating_hours, fuel_consumed_l
    FROM staging_daily_production
    WHERE date_id = p_date_id;

    GET DIAGNOSTICS p_loaded = ROW_COUNT;
    p_validated := p_loaded;

    -- Очистка staging
    DELETE FROM staging_daily_production WHERE date_id = p_date_id;

    RAISE NOTICE 'Шаг 4: Загрузка завершена. Добавлено в факт: % зап.', p_loaded;
    COMMIT;
END;
$$;

-- Тестирование процедуры
TRUNCATE TABLE staging_daily_production;
TRUNCATE TABLE staging_rejected;

-- Вставка тестовых данных (корректные и некорректные)
INSERT INTO staging_daily_production (date_id, equipment_id, shift_id, operator_id, tons_mined, trips_count, operating_hours, fuel_consumed_l)
VALUES
    (20250120, 1, 1, 10, 500.5, 12, 11.5, 250.0),   -- корректная запись
    (20250120, 1, 2, 10, -50.0, 5, 4.0, 80.0),      -- отрицательная добыча
    (20250120, 1, 1, 999999, 300.0, 8, 9.0, 150.0); -- неизвестный оператор

SELECT * FROM staging_daily_production;

CALL process_daily_production(20250120, 0, 0, 0);

-- Проверка результатов
SELECT COUNT(*) AS fact_count FROM fact_production WHERE date_id = 20250120;
SELECT * FROM staging_rejected;

-- Очистка тестовых данных
DELETE FROM fact_production WHERE date_id = 20250120;
TRUNCATE TABLE staging_daily_production;
TRUNCATE TABLE staging_rejected;

-- Очистка тестовых объектов после лабораторной работы

DROP FUNCTION IF EXISTS calc_oee(NUMERIC, NUMERIC, NUMERIC, NUMERIC);
DROP FUNCTION IF EXISTS classify_downtime(NUMERIC);
DROP FUNCTION IF EXISTS get_equipment_summary(INT, INT, INT);
DROP FUNCTION IF EXISTS get_production_filtered(INT, INT, INT, INT, INT);
DROP FUNCTION IF EXISTS count_fact_records(TEXT, INT, INT);
DROP FUNCTION IF EXISTS build_production_report(TEXT, INT, INT, TEXT);

DROP PROCEDURE IF EXISTS archive_old_telemetry(INT, INT, INT);
DROP PROCEDURE IF EXISTS process_daily_production(INT, INT, INT, INT);

DROP TABLE IF EXISTS archive_telemetry;
DROP TABLE IF EXISTS staging_daily_production;
DROP TABLE IF EXISTS staging_rejected;
