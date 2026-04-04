-- Лабораторная работа - Модуль 11

-- Задание 1. Представление - сводка по добыче
CREATE OR REPLACE VIEW v_daily_production_summary AS
SELECT
    d.full_date,
    m.mine_name,
    s.shift_name,
    COUNT(*) AS record_count,
    SUM(fp.tons_mined) AS total_tons,
    SUM(fp.fuel_consumed_l) AS total_fuel,
    ROUND(AVG(fp.trips_count), 2) AS avg_trips
FROM fact_production fp
JOIN dim_date d
    ON fp.date_id = d.date_id
JOIN dim_mine m
    ON fp.mine_id = m.mine_id
JOIN dim_shift s
    ON fp.shift_id = s.shift_id
GROUP BY d.full_date, m.mine_name, s.shift_name;

SELECT *
FROM v_daily_production_summary
WHERE full_date BETWEEN DATE '2024-03-01' AND DATE '2024-03-31'
  AND mine_name = 'Шахта "Северная"'
  AND record_count > 5
ORDER BY full_date, shift_name;

-- Задание 2. Представление с ограничением обновления
CREATE OR REPLACE VIEW v_unplanned_downtime AS
SELECT *
FROM fact_equipment_downtime
WHERE is_planned = FALSE
WITH CHECK OPTION;

SELECT COUNT(*) AS view_count
FROM v_unplanned_downtime;

SELECT COUNT(*) AS base_table_count
FROM fact_equipment_downtime;

-- Задание 3. Материализованное представление для качества руды
CREATE MATERIALIZED VIEW mv_monthly_ore_quality AS
SELECT
    m.mine_name,
    d.year_month,
    COUNT(*) AS sample_count,
    ROUND(AVG(foq.fe_content), 2) AS avg_fe,
    MIN(foq.fe_content) AS min_fe,
    MAX(foq.fe_content) AS max_fe,
    ROUND(AVG(foq.sio2_content), 2) AS avg_sio2,
    ROUND(AVG(foq.moisture), 2) AS avg_moisture
FROM fact_ore_quality foq
JOIN dim_mine m
    ON foq.mine_id = m.mine_id
JOIN dim_date d
    ON foq.date_id = d.date_id
GROUP BY m.mine_name, d.year_month;

CREATE INDEX idx_mv_monthly_ore_quality_mine_month
    ON mv_monthly_ore_quality (mine_name, year_month);

EXPLAIN ANALYZE
SELECT *
FROM mv_monthly_ore_quality
WHERE mine_name = 'Шахта "Северная"'
ORDER BY year_month;

EXPLAIN ANALYZE
SELECT
    m.mine_name,
    d.year_month,
    COUNT(*) AS sample_count,
    ROUND(AVG(foq.fe_content), 2) AS avg_fe,
    MIN(foq.fe_content) AS min_fe,
    MAX(foq.fe_content) AS max_fe,
    ROUND(AVG(foq.sio2_content), 2) AS avg_sio2,
    ROUND(AVG(foq.moisture), 2) AS avg_moisture
FROM fact_ore_quality foq
JOIN dim_mine m
    ON foq.mine_id = m.mine_id
JOIN dim_date d
    ON foq.date_id = d.date_id
WHERE m.mine_name = 'Шахта "Северная"'
GROUP BY m.mine_name, d.year_month
ORDER BY d.year_month;

REFRESH MATERIALIZED VIEW mv_monthly_ore_quality;

-- Задание 4. Производная таблица - ранжирование операторов
SELECT
    sub.shift_name,
    sub.operator_name,
    sub.total_mined
FROM (
    SELECT
        s.shift_name,
        o.last_name || ' ' || LEFT(o.first_name, 1) || '.' AS operator_name,
        SUM(fp.tons_mined) AS total_mined,
        ROW_NUMBER() OVER (
            PARTITION BY fp.shift_id
            ORDER BY SUM(fp.tons_mined) DESC
        ) AS rn
    FROM fact_production fp
    JOIN dim_shift s
        ON fp.shift_id = s.shift_id
    JOIN dim_operator o
        ON fp.operator_id = o.operator_id
    WHERE fp.date_id BETWEEN 20240101 AND 20240331
    GROUP BY fp.shift_id, s.shift_name, o.last_name, o.first_name
) sub
WHERE sub.rn = 1
ORDER BY sub.shift_name;

-- Задание 5. CTE - комплексный отчёт по эффективности
WITH production_cte AS (
    SELECT
        fp.mine_id,
        SUM(fp.operating_hours) AS operating_hours,
        SUM(fp.tons_mined) AS total_tons
    FROM fact_production fp
    WHERE fp.date_id BETWEEN 20240101 AND 20240331
    GROUP BY fp.mine_id
),
downtime_cte AS (
    SELECT
        e.mine_id,
        SUM(fd.duration_min) / 60.0 AS downtime_hours
    FROM fact_equipment_downtime fd
    JOIN dim_equipment e
        ON fd.equipment_id = e.equipment_id
    WHERE fd.date_id BETWEEN 20240101 AND 20240331
    GROUP BY e.mine_id
)
SELECT
    m.mine_name,
    COALESCE(p.operating_hours, 0) AS operating_hours,
    COALESCE(d.downtime_hours, 0) AS downtime_hours,
    COALESCE(p.total_tons, 0) AS total_tons,
    ROUND(
        COALESCE(p.operating_hours, 0)
        / NULLIF(COALESCE(p.operating_hours, 0) + COALESCE(d.downtime_hours, 0), 0) * 100,
        2
    ) AS availability_pct
FROM dim_mine m
LEFT JOIN production_cte p
    ON m.mine_id = p.mine_id
LEFT JOIN downtime_cte d
    ON m.mine_id = d.mine_id
ORDER BY availability_pct ASC;

-- Задание 6. Табличная функция - отчёт по простоям
CREATE OR REPLACE FUNCTION fn_equipment_downtime_report(
    p_equipment_id INT,
    p_date_from INT,
    p_date_to INT
)
RETURNS TABLE (
    full_date DATE,
    reason_name TEXT,
    reason_category TEXT,
    duration_min NUMERIC,
    duration_hours NUMERIC,
    is_planned BOOLEAN,
    comment TEXT
)
LANGUAGE sql
AS $$
    SELECT
        d.full_date,
        dr.reason_name,
        dr.category AS reason_category,
        fd.duration_min,
        ROUND(fd.duration_min / 60.0, 1) AS duration_hours,
        fd.is_planned,
        fd.comment
    FROM fact_equipment_downtime fd
    JOIN dim_date d
        ON fd.date_id = d.date_id
    JOIN dim_downtime_reason dr
        ON fd.reason_id = dr.reason_id
    WHERE fd.equipment_id = p_equipment_id
      AND fd.date_id BETWEEN p_date_from AND p_date_to
    ORDER BY d.full_date
$$;

SELECT *
FROM fn_equipment_downtime_report(3, 20240101, 20240131);

SELECT
    e.equipment_id,
    e.equipment_name,
    r.full_date,
    r.reason_name,
    r.reason_category,
    r.duration_min,
    r.duration_hours,
    r.is_planned,
    r.comment
FROM dim_equipment e
CROSS JOIN LATERAL fn_equipment_downtime_report(e.equipment_id, 20240101, 20240131) r
WHERE e.mine_id = 1
ORDER BY e.equipment_name, r.full_date;

-- Задание 7. Рекурсивный CTE - иерархия локаций
WITH RECURSIVE location_tree AS (
    SELECT
        lh.location_id,
        lh.parent_id,
        lh.location_name,
        lh.location_type,
        lh.location_name::TEXT AS full_path,
        0 AS depth,
        lh.location_name::TEXT AS indented_name
    FROM dim_location_hierarchy lh
    WHERE lh.parent_id IS NULL

    UNION ALL

    SELECT
        child.location_id,
        child.parent_id,
        child.location_name,
        child.location_type,
        parent.full_path || ' → ' || child.location_name,
        parent.depth + 1,
        REPEAT('  ', parent.depth + 1) || child.location_name
    FROM dim_location_hierarchy child
    JOIN location_tree parent
        ON child.parent_id = parent.location_id
)
SELECT
    indented_name AS hierarchy,
    location_type,
    full_path,
    depth
FROM location_tree
ORDER BY full_path;

WITH RECURSIVE reverse_path AS (
    SELECT
        lh.location_id,
        lh.parent_id,
        lh.location_name,
        lh.location_type,
        0 AS depth
    FROM dim_location_hierarchy lh
    WHERE lh.location_id = 13

    UNION ALL

    SELECT
        parent.location_id,
        parent.parent_id,
        parent.location_name,
        parent.location_type,
        child.depth + 1
    FROM dim_location_hierarchy parent
    JOIN reverse_path child
        ON child.parent_id = parent.location_id
)
SELECT
    location_id,
    location_name,
    location_type,
    depth
FROM reverse_path
ORDER BY depth DESC;

-- Задание 8. Рекурсивный CTE - генерация календаря и заполнение пропусков
WITH RECURSIVE feb_calendar AS (
    SELECT DATE '2024-02-01' AS full_date
    UNION ALL
    SELECT full_date + INTERVAL '1 day'
    FROM feb_calendar
    WHERE full_date < DATE '2024-02-29'
),
calendar_with_dim AS (
    SELECT
        fc.full_date::DATE AS full_date,
        d.date_id,
        d.day_of_week_name,
        d.is_weekend
    FROM feb_calendar fc
    JOIN dim_date d
        ON d.full_date = fc.full_date::DATE
)
SELECT
    c.full_date,
    c.day_of_week_name,
    CASE
        WHEN c.is_weekend THEN 'выходной'
        ELSE 'рабочий'
    END AS day_type
FROM calendar_with_dim c
LEFT JOIN fact_production fp
    ON fp.date_id = c.date_id
   AND fp.mine_id = 1
WHERE fp.production_id IS NULL
  AND c.is_weekend = FALSE
ORDER BY c.full_date;

WITH RECURSIVE feb_calendar AS (
    SELECT DATE '2024-02-01' AS full_date
    UNION ALL
    SELECT full_date + INTERVAL '1 day'
    FROM feb_calendar
    WHERE full_date < DATE '2024-02-29'
),
calendar_with_dim AS (
    SELECT
        fc.full_date::DATE AS full_date,
        d.date_id,
        d.day_of_week_name,
        d.is_weekend
    FROM feb_calendar fc
    JOIN dim_date d
        ON d.full_date = fc.full_date::DATE
)
SELECT COUNT(*) AS lost_work_days
FROM calendar_with_dim c
LEFT JOIN fact_production fp
    ON fp.date_id = c.date_id
   AND fp.mine_id = 1
WHERE fp.production_id IS NULL
  AND c.is_weekend = FALSE;

-- Задание 9. CTE для скользящего среднего
WITH daily_prod AS (
    SELECT
        d.date_id,
        d.full_date,
        SUM(fp.tons_mined) AS daily_tons
    FROM fact_production fp
    JOIN dim_date d
        ON fp.date_id = d.date_id
    WHERE fp.mine_id = 1
      AND fp.date_id BETWEEN 20240101 AND 20240331
    GROUP BY d.date_id, d.full_date
),
moving_stats AS (
    SELECT
        date_id,
        full_date,
        daily_tons,
        AVG(daily_tons) OVER (
            ORDER BY date_id
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS moving_avg_7d,
        MAX(daily_tons) OVER (
            ORDER BY date_id
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS moving_max_7d
    FROM daily_prod
)
SELECT
    full_date,
    daily_tons,
    ROUND(moving_avg_7d, 2) AS moving_avg_7d,
    moving_max_7d,
    ROUND(
        (daily_tons - moving_avg_7d) / NULLIF(moving_avg_7d, 0) * 100,
        2
    ) AS deviation_pct,
    CASE
        WHEN ABS((daily_tons - moving_avg_7d) / NULLIF(moving_avg_7d, 0) * 100) > 20
            THEN 'Аномалия'
        ELSE ''
    END AS anomaly_flag
FROM moving_stats
ORDER BY full_date;

-- Задание 10. Комплексное задание: VIEW + CTE + функция
CREATE OR REPLACE VIEW v_ore_quality_detail AS
SELECT
    foq.*,
    m.mine_name,
    s.shift_name,
    og.grade_name,
    CASE
        WHEN foq.fe_content >= 65 THEN 'Богатая'
        WHEN foq.fe_content >= 55 THEN 'Средняя'
        ELSE 'Бедная'
    END AS quality_category
FROM fact_ore_quality foq
JOIN dim_mine m
    ON foq.mine_id = m.mine_id
JOIN dim_shift s
    ON foq.shift_id = s.shift_id
JOIN dim_ore_grade og
    ON foq.ore_grade_id = og.ore_grade_id;

CREATE OR REPLACE FUNCTION fn_ore_quality_stats(
    p_mine_id INT,
    p_year INT,
    p_month INT
)
RETURNS TABLE (
    sample_count BIGINT,
    avg_fe NUMERIC,
    stddev_fe NUMERIC,
    good_pct NUMERIC
)
LANGUAGE sql
AS $$
    SELECT
        COUNT(*) AS sample_count,
        ROUND(AVG(fe_content), 2) AS avg_fe,
        ROUND(STDDEV_SAMP(fe_content), 2) AS stddev_fe,
        ROUND(
            100.0 * COUNT(*) FILTER (WHERE fe_content >= 55)
            / NULLIF(COUNT(*), 0),
            2
        ) AS good_pct
    FROM fact_ore_quality foq
    JOIN dim_date d
        ON foq.date_id = d.date_id
    WHERE foq.mine_id = p_mine_id
      AND d.year = p_year
      AND d.month = p_month
$$;

WITH monthly_quality AS (
    SELECT
        mine_name,
        DATE_TRUNC('month', full_date)::DATE AS month_start,
        ROUND(AVG(fe_content), 2) AS avg_fe,
        COUNT(*) AS sample_count
    FROM v_ore_quality_detail
    GROUP BY mine_name, DATE_TRUNC('month', full_date)
),
moving_quality AS (
    SELECT
        mine_name,
        month_start,
        avg_fe,
        sample_count,
        ROUND(
            AVG(avg_fe) OVER (
                PARTITION BY mine_name
                ORDER BY month_start
                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
            ),
            2
        ) AS moving_avg_fe_3m
    FROM monthly_quality
)
SELECT
    mine_name,
    month_start,
    avg_fe,
    moving_avg_fe_3m,
    CASE
        WHEN avg_fe > moving_avg_fe_3m THEN 'рост'
        WHEN avg_fe < moving_avg_fe_3m THEN 'снижение'
        ELSE 'без изменений'
    END AS trend
FROM moving_quality
ORDER BY mine_name, month_start;

SELECT
    m.mine_name,
    stats.*
FROM dim_mine m
CROSS JOIN LATERAL fn_ore_quality_stats(m.mine_id, 2024, 3) stats
WHERE m.status = 'active';

-- Очистка после лабораторной работы
DROP VIEW IF EXISTS v_daily_production_summary CASCADE;
DROP VIEW IF EXISTS v_unplanned_downtime CASCADE;
DROP VIEW IF EXISTS v_ore_quality_detail CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_ore_quality;
DROP FUNCTION IF EXISTS fn_equipment_downtime_report(INT, INT, INT);
DROP FUNCTION IF EXISTS fn_ore_quality_stats(INT, INT, INT);
