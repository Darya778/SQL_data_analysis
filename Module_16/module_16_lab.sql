-- Лабораторная работа - Модуль 16

-- Задание 1. Cтатистика по шахтам
DO $$
DECLARE
    v_mine_count      INT;
    v_total_production NUMERIC;
    v_avg_fe          NUMERIC;
    v_downtime_count  INT;
BEGIN
    SELECT COUNT(*) INTO v_mine_count FROM dim_mine;

    SELECT COALESCE(SUM(tons_mined), 0)
    INTO v_total_production
    FROM fact_production fp
    JOIN dim_date dd ON fp.date_id = dd.date_id
    WHERE dd.full_date BETWEEN '2025-01-01' AND '2025-01-31';

    SELECT COALESCE(ROUND(AVG(fe_content), 1), 0)
    INTO v_avg_fe
    FROM fact_ore_quality;

    SELECT COUNT(*)
    INTO v_downtime_count
    FROM fact_equipment_downtime;

    RAISE NOTICE '===== Сводка по предприятию «Руда+» =====';
    RAISE NOTICE 'Количество шахт: %', v_mine_count;
    RAISE NOTICE 'Добыча за январь 2025: % т', v_total_production;
    RAISE NOTICE 'Среднее содержание Fe: % %%', v_avg_fe;
    RAISE NOTICE 'Количество простоев: %', v_downtime_count;
    RAISE NOTICE '==========================================';
END $$;

-- Задание 2. Переменные и классификация - категории оборудования
DO $$
DECLARE
    rec              RECORD;
    v_age_years      NUMERIC;
    v_category       VARCHAR;
    v_new_count      INT := 0;
    v_working_count  INT := 0;
    v_attention_count INT := 0;
    v_replace_count  INT := 0;
BEGIN
    FOR rec IN
        SELECT
            equipment_id,
            equipment_name,
            equipment_type,
            COALESCE(commissioning_date, CURRENT_DATE - (random() * 4000)::INT) AS comm_date
        FROM dim_equipment
    LOOP
        v_age_years := EXTRACT(YEAR FROM age(CURRENT_DATE, rec.comm_date))
                     + EXTRACT(MONTH FROM age(CURRENT_DATE, rec.comm_date)) / 12.0;

        IF v_age_years < 2 THEN
            v_category := 'Новое';
            v_new_count := v_new_count + 1;
        ELSIF v_age_years < 5 THEN
            v_category := 'Рабочее';
            v_working_count := v_working_count + 1;
        ELSIF v_age_years < 10 THEN
            v_category := 'Требует внимания';
            v_attention_count := v_attention_count + 1;
        ELSE
            v_category := 'На замену';
            v_replace_count := v_replace_count + 1;
        END IF;

        RAISE NOTICE 'Оборудование: % | Тип: % | Возраст: % лет | Категория: %',
            rec.equipment_name, rec.equipment_type, ROUND(v_age_years, 1), v_category;
    END LOOP;

    RAISE NOTICE '--- Сводка по категориям ---';
    RAISE NOTICE 'Новое: %', v_new_count;
    RAISE NOTICE 'Рабочее: %', v_working_count;
    RAISE NOTICE 'Требует внимания: %', v_attention_count;
    RAISE NOTICE 'На замену: %', v_replace_count;
END $$;

-- Задание 3. Циклы - подневной анализ добычи
DO $$
DECLARE
    i                INT;
    v_date           DATE;
    v_daily_tons     NUMERIC;
    v_running_total  NUMERIC := 0;
    v_prev_avg       NUMERIC := 0;
    v_best_day       DATE;
    v_best_tons      NUMERIC := 0;
    v_is_record      TEXT;
BEGIN
    FOR i IN 1..14 LOOP
        v_date := DATE '2025-01-01' + (i - 1);

        SELECT COALESCE(SUM(tons_mined), 0)
        INTO v_daily_tons
        FROM fact_production fp
        JOIN dim_date dd ON fp.date_id = dd.date_id
        WHERE dd.full_date = v_date;

        v_running_total := v_running_total + v_daily_tons;

        IF i > 1 AND v_daily_tons > v_prev_avg THEN
            v_is_record := '| РЕКОРД';
        ELSE
            v_is_record := '';
        END IF;

        RAISE NOTICE 'День %: % т | Нарастающий: % т %',
            TO_CHAR(v_date, 'DD'), ROUND(v_daily_tons, 1), ROUND(v_running_total, 1), v_is_record;

        v_prev_avg := v_running_total / i;

        IF v_daily_tons > v_best_tons THEN
            v_best_tons := v_daily_tons;
            v_best_day  := v_date;
        END IF;
    END LOOP;

    RAISE NOTICE '--- Итог ---';
    RAISE NOTICE 'Общий итог: % т', ROUND(v_running_total, 1);
    RAISE NOTICE 'Средняя добыча в день: % т', ROUND(v_running_total / 14, 1);
    RAISE NOTICE 'Лучший день: % — % т', v_best_day, ROUND(v_best_tons, 1);
END $$;

-- Задание 4. WHILE - мониторинг порога простоев
DO $$
DECLARE
    v_threshold      NUMERIC := 500;
    v_accumulated    NUMERIC := 0;
    v_current_date   DATE := '2025-01-01';
    v_end_date       DATE := '2025-01-31';
    v_daily_downtime NUMERIC;
    v_found          BOOLEAN := FALSE;
BEGIN
    WHILE v_current_date <= v_end_date LOOP
        SELECT COALESCE(SUM(downtime_minutes) / 60.0, 0)
        INTO v_daily_downtime
        FROM fact_equipment_downtime fed
        JOIN dim_date dd ON fed.date_id = dd.date_id
        WHERE dd.full_date = v_current_date;

        v_accumulated := v_accumulated + v_daily_downtime;

        IF v_accumulated >= v_threshold THEN
            RAISE NOTICE 'Порог % ч достигнут к дате: % (накоплено: % ч)',
                v_threshold, v_current_date, ROUND(v_accumulated, 1);
            v_found := TRUE;
            EXIT;
        END IF;

        v_current_date := v_current_date + 1;
        CONTINUE;
    END LOOP;

    IF NOT v_found THEN
        RAISE NOTICE 'Порог % ч за январь 2025 не достигнут. Накоплено: % ч',
            v_threshold, ROUND(v_accumulated, 1);
    END IF;
END $$;

-- Задание 5. CASE и FOREACH - анализ датчиков
DO $$
DECLARE
    v_sensor_types   INT[];
    v_type_id        INT;
    v_type_name      VARCHAR;
    v_sensor_count   BIGINT;
    v_reading_count  BIGINT;
    v_per_sensor     NUMERIC;
    v_status         VARCHAR;
BEGIN
    SELECT ARRAY_AGG(sensor_type_id)
    INTO v_sensor_types
    FROM dim_sensor_type;

    FOREACH v_type_id IN ARRAY v_sensor_types LOOP
        SELECT sensor_type_name
        INTO v_type_name
        FROM dim_sensor_type
        WHERE sensor_type_id = v_type_id;

        SELECT COUNT(*)
        INTO v_sensor_count
        FROM dim_sensor
        WHERE sensor_type_id = v_type_id;

        SELECT COUNT(*)
        INTO v_reading_count
        FROM fact_telemetry ft
        JOIN dim_sensor ds ON ft.sensor_id = ds.sensor_id
        JOIN dim_date dd ON ft.date_id = dd.date_id
        WHERE ds.sensor_type_id = v_type_id
          AND dd.full_date BETWEEN '2025-01-01' AND '2025-01-31';

        v_per_sensor := CASE WHEN v_sensor_count > 0
                             THEN v_reading_count::NUMERIC / v_sensor_count
                             ELSE 0 END;

        v_status := CASE
            WHEN v_per_sensor > 1000 THEN 'Активно работает'
            WHEN v_per_sensor >= 100 THEN 'Нормальная работа'
            WHEN v_per_sensor >= 1   THEN 'Редкие показания'
            ELSE 'Нет данных'
        END;

        RAISE NOTICE 'Тип: % | Датчиков: % | Показаний: % | Статус: %',
            v_type_name, v_sensor_count, v_reading_count, v_status;
    END LOOP;
END $$;

-- Задание 6. Курсор - пакетное формирование отчёта по сменам
CREATE TABLE IF NOT EXISTS report_shift_summary (
    report_date    DATE,
    shift_name     VARCHAR(50),
    mine_name      VARCHAR(100),
    total_tons     NUMERIC(12,2),
    equipment_used INT,
    efficiency     NUMERIC(5,1),
    created_at     TIMESTAMP DEFAULT NOW()
);

DO $$
DECLARE
    cur_date         CURSOR FOR
        SELECT full_date
        FROM dim_date
        WHERE full_date BETWEEN '2025-01-01' AND '2025-01-15'
        ORDER BY full_date;

    rec_date         RECORD;
    rec_shift        RECORD;
    v_rows_inserted  INT;
    v_total_inserted INT := 0;
BEGIN
    OPEN cur_date;

    LOOP
        FETCH cur_date INTO rec_date;
        EXIT WHEN NOT FOUND;

        FOR rec_shift IN
            SELECT
                ds.shift_name,
                dm.mine_name,
                COALESCE(SUM(fp.tons_mined), 0)                                        AS total_tons,
                COUNT(DISTINCT fp.equipment_id)                                         AS equipment_used,
                CASE WHEN COUNT(DISTINCT fp.equipment_id) > 0
                     THEN ROUND(
                         COALESCE(SUM(fp.operating_hours), 0)
                         / (COUNT(DISTINCT fp.equipment_id) * 8.0) * 100, 1)
                     ELSE 0 END                                                         AS efficiency
            FROM dim_shift ds
            CROSS JOIN dim_mine dm
            LEFT JOIN fact_production fp
                ON fp.shift_id = ds.shift_id
               AND fp.mine_id  = dm.mine_id
               AND fp.date_id  = (SELECT date_id FROM dim_date WHERE full_date = rec_date.full_date)
            GROUP BY ds.shift_name, dm.mine_name
        LOOP
            INSERT INTO report_shift_summary
                (report_date, shift_name, mine_name, total_tons, equipment_used, efficiency)
            VALUES
                (rec_date.full_date, rec_shift.shift_name, rec_shift.mine_name,
                 rec_shift.total_tons, rec_shift.equipment_used, rec_shift.efficiency);
        END LOOP;

        GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
        v_total_inserted := v_total_inserted + v_rows_inserted;

        RAISE NOTICE 'Обработана дата: % | Вставлено строк: %', rec_date.full_date, v_rows_inserted;
    END LOOP;

    CLOSE cur_date;

    RAISE NOTICE 'Готово. Всего вставлено строк: %', v_total_inserted;
END $$;

-- Задание 7. RETURN NEXT - функция генерации отчёта
CREATE OR REPLACE FUNCTION get_quality_trend(p_year INT, p_mine_id INT DEFAULT NULL)
RETURNS TABLE (
    month_num      INT,
    month_name     VARCHAR,
    samples_count  BIGINT,
    avg_fe         NUMERIC,
    min_fe         NUMERIC,
    max_fe         NUMERIC,
    running_avg_fe NUMERIC,
    trend          VARCHAR
)
LANGUAGE plpgsql AS $$
DECLARE
    i                INT;
    v_month_name     VARCHAR;
    v_samples        BIGINT;
    v_avg            NUMERIC;
    v_min            NUMERIC;
    v_max            NUMERIC;
    v_running_sum    NUMERIC := 0;
    v_running_count  INT     := 0;
    v_prev_avg       NUMERIC := NULL;
    v_trend          VARCHAR;
BEGIN
    FOR i IN 1..12 LOOP
        v_month_name := TO_CHAR(TO_DATE(i::TEXT, 'MM'), 'Month');

        SELECT
            COUNT(*),
            ROUND(AVG(fe_content), 2),
            ROUND(MIN(fe_content), 2),
            ROUND(MAX(fe_content), 2)
        INTO v_samples, v_avg, v_min, v_max
        FROM fact_ore_quality foq
        JOIN dim_date dd ON foq.date_id = dd.date_id
        WHERE dd.year  = p_year
          AND dd.month = i
          AND (p_mine_id IS NULL OR foq.mine_id = p_mine_id);

        IF v_samples = 0 THEN
            CONTINUE;
        END IF;

        v_running_sum   := v_running_sum + v_avg * v_samples;
        v_running_count := v_running_count + v_samples;

        v_trend := CASE
            WHEN v_prev_avg IS NULL        THEN 'Нет данных'
            WHEN v_avg > v_prev_avg + 0.1  THEN 'Улучшение'
            WHEN v_avg < v_prev_avg - 0.1  THEN 'Ухудшение'
            ELSE 'Стабильно'
        END;

        month_num      := i;
        month_name     := TRIM(v_month_name);
        samples_count  := v_samples;
        avg_fe         := v_avg;
        min_fe         := v_min;
        max_fe         := v_max;
        running_avg_fe := ROUND(v_running_sum / v_running_count, 2);
        trend          := v_trend;

        RETURN NEXT;

        v_prev_avg := v_avg;
    END LOOP;
END $$;

-- Задание 8. Комплексная валидация данных
CREATE OR REPLACE FUNCTION validate_mes_data(p_date_from INT, p_date_to INT)
RETURNS TABLE (
    check_id        INT,
    check_name      VARCHAR,
    severity        VARCHAR,
    affected_rows   BIGINT,
    details         TEXT,
    recommendation  TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_count BIGINT;
BEGIN
    -- Проверка 1: Отрицательные значения добычи
    SELECT COUNT(*) INTO v_count
    FROM fact_production fp
    JOIN dim_date dd ON fp.date_id = dd.date_id
    WHERE dd.date_id BETWEEN p_date_from AND p_date_to
      AND fp.tons_mined < 0;

    check_id       := 1;
    check_name     := 'Отрицательные значения добычи';
    severity       := CASE WHEN v_count > 0 THEN 'ОШИБКА' ELSE 'ИНФО' END;
    affected_rows  := v_count;
    details        := 'Записи с tons_mined < 0: ' || v_count;
    recommendation := 'Проверить источник данных и исправить отрицательные значения';
    RETURN NEXT;

    -- Проверка 2: Аномально большая добыча (> 500 т за запись)
    SELECT COUNT(*) INTO v_count
    FROM fact_production fp
    JOIN dim_date dd ON fp.date_id = dd.date_id
    WHERE dd.date_id BETWEEN p_date_from AND p_date_to
      AND fp.tons_mined > 500;

    check_id       := 2;
    check_name     := 'Аномально большая добыча (> 500 т)';
    severity       := CASE WHEN v_count > 0 THEN 'ПРЕДУПРЕЖДЕНИЕ' ELSE 'ИНФО' END;
    affected_rows  := v_count;
    details        := 'Записей с добычей > 500 т: ' || v_count;
    recommendation := 'Верифицировать записи с нетипично большими значениями добычи';
    RETURN NEXT;

    -- Проверка 3: Нулевые рабочие часы при ненулевой добыче
    SELECT COUNT(*) INTO v_count
    FROM fact_production fp
    JOIN dim_date dd ON fp.date_id = dd.date_id
    WHERE dd.date_id BETWEEN p_date_from AND p_date_to
      AND COALESCE(fp.operating_hours, 0) = 0
      AND fp.tons_mined > 0;

    check_id       := 3;
    check_name     := 'Нулевые рабочие часы при ненулевой добыче';
    severity       := CASE WHEN v_count > 0 THEN 'ОШИБКА' ELSE 'ИНФО' END;
    affected_rows  := v_count;
    details        := 'Записей с operating_hours = 0 и tons_mined > 0: ' || v_count;
    recommendation := 'Заполнить данные о рабочих часах или проверить логику загрузки';
    RETURN NEXT;

    -- Проверка 4: Рабочие дни без записей о добыче
    SELECT COUNT(*) INTO v_count
    FROM dim_date dd
    WHERE dd.date_id BETWEEN p_date_from AND p_date_to
      AND dd.is_working_day = TRUE
      AND NOT EXISTS (
          SELECT 1 FROM fact_production fp WHERE fp.date_id = dd.date_id
      );

    check_id       := 4;
    check_name     := 'Рабочие дни без записей о добыче';
    severity       := CASE WHEN v_count > 0 THEN 'ПРЕДУПРЕЖДЕНИЕ' ELSE 'ИНФО' END;
    affected_rows  := v_count;
    details        := 'Рабочих дней без записей о добыче: ' || v_count;
    recommendation := 'Уточнить причину отсутствия данных (плановый простой / потеря данных)';
    RETURN NEXT;

    -- Проверка 5: Содержание Fe вне диапазона 0-100%
    SELECT COUNT(*) INTO v_count
    FROM fact_ore_quality foq
    JOIN dim_date dd ON foq.date_id = dd.date_id
    WHERE dd.date_id BETWEEN p_date_from AND p_date_to
      AND (foq.fe_content < 0 OR foq.fe_content > 100);

    check_id       := 5;
    check_name     := 'Содержание Fe вне диапазона 0-100%';
    severity       := CASE WHEN v_count > 0 THEN 'ОШИБКА' ELSE 'ИНФО' END;
    affected_rows  := v_count;
    details        := 'Записей с некорректным fe_content: ' || v_count;
    recommendation := 'Исправить значения и добавить CHECK-ограничение на уровне таблицы';
    RETURN NEXT;

    -- Проверка 6: Простои длительностью > 24 часов (> 1440 минут)
    SELECT COUNT(*) INTO v_count
    FROM fact_equipment_downtime fed
    JOIN dim_date dd ON fed.date_id = dd.date_id
    WHERE dd.date_id BETWEEN p_date_from AND p_date_to
      AND fed.downtime_minutes > 1440;

    check_id       := 6;
    check_name     := 'Простои длительностью > 24 часов';
    severity       := CASE WHEN v_count > 0 THEN 'ПРЕДУПРЕЖДЕНИЕ' ELSE 'ИНФО' END;
    affected_rows  := v_count;
    details        := 'Записей с downtime_minutes > 1440: ' || v_count;
    recommendation := 'Проверить правильность заполнения — возможно, указаны часы вместо минут';
    RETURN NEXT;

    -- Проверка 7: Оборудование без телеметрии за период
    SELECT COUNT(*) INTO v_count
    FROM dim_equipment de
    WHERE NOT EXISTS (
        SELECT 1
        FROM fact_telemetry ft
        JOIN dim_date dd ON ft.date_id = dd.date_id
        WHERE ft.equipment_id = de.equipment_id
          AND dd.date_id BETWEEN p_date_from AND p_date_to
    );

    check_id       := 7;
    check_name     := 'Оборудование без телеметрии за период';
    severity       := CASE WHEN v_count > 0 THEN 'ПРЕДУПРЕЖДЕНИЕ' ELSE 'ИНФО' END;
    affected_rows  := v_count;
    details        := 'Единиц оборудования без телеметрии: ' || v_count;
    recommendation := 'Проверить работоспособность датчиков на данных единицах';
    RETURN NEXT;

    -- Проверка 8: Дублирование записей (оборудование + смена + дата > 1 записи)
    SELECT COUNT(*) INTO v_count
    FROM (
        SELECT equipment_id, shift_id, date_id, COUNT(*) AS cnt
        FROM fact_production fp
        JOIN dim_date dd ON fp.date_id = dd.date_id
        WHERE dd.date_id BETWEEN p_date_from AND p_date_to
        GROUP BY equipment_id, shift_id, date_id
        HAVING COUNT(*) > 1
    ) dups;

    check_id       := 8;
    check_name     := 'Дублирование записей (оборудование + смена + дата)';
    severity       := CASE WHEN v_count > 0 THEN 'ОШИБКА' ELSE 'ИНФО' END;
    affected_rows  := v_count;
    details        := 'Групп с дублями: ' || v_count;
    recommendation := 'Добавить UNIQUE-ограничение (equipment_id, shift_id, date_id) и удалить дубли';
    RETURN NEXT;
END $$;
