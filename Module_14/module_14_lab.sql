-- Лабораторная работа - Модуль 14

-- Задание 1. ROLLUP - сменный рапорт с подитогами
SELECT
    CASE
        WHEN GROUPING(m.mine_name) = 1 THEN '== ИТОГО =='
        ELSE m.mine_name
    END AS mine_name,
    CASE
        WHEN GROUPING(m.mine_name) = 1 THEN '—'
        WHEN GROUPING(s.shift_name) = 1 THEN 'Итого по шахте'
        ELSE s.shift_name
    END AS shift_name,
    SUM(fp.tons_mined) AS total_tons,
    COUNT(DISTINCT fp.equipment_id) AS equipment_count
FROM fact_production fp
JOIN dim_mine m
    ON m.mine_id = fp.mine_id
JOIN dim_shift s
    ON s.shift_id = fp.shift_id
WHERE fp.date_id = 20240115
GROUP BY ROLLUP(m.mine_name, s.shift_name)
ORDER BY
    GROUPING(m.mine_name),
    m.mine_name,
    GROUPING(s.shift_name),
    s.shift_name;

-- Задание 2. CUBE - матрица «шахта x тип оборудования»
SELECT
    CASE
        WHEN GROUPING(m.mine_name) = 1 THEN 'ВСЕ ШАХТЫ'
        ELSE m.mine_name
    END AS mine_name,
    CASE
        WHEN GROUPING(et.type_name) = 1 THEN 'ВСЕ ТИПЫ'
        ELSE et.type_name
    END AS type_name,
    SUM(fp.tons_mined) AS total_tons,
    ROUND(
        SUM(fp.tons_mined)::NUMERIC /
        NULLIF(COUNT(DISTINCT fp.equipment_id), 0), 2
    ) AS avg_tons_per_equipment,
    GROUPING(m.mine_name, et.type_name) AS grouping_level
FROM fact_production fp
JOIN dim_mine m
    ON m.mine_id = fp.mine_id
JOIN dim_equipment e
    ON e.equipment_id = fp.equipment_id
JOIN dim_equipment_type et
    ON et.equipment_type_id = e.equipment_type_id
WHERE fp.date_id BETWEEN 20240101 AND 20240331
GROUP BY CUBE(m.mine_name, et.type_name)
ORDER BY grouping_level, m.mine_name, et.type_name;

-- Задание 3. GROUPING SETS - сводка KPI по нескольким срезам
SELECT
    CASE
        WHEN GROUPING(m.mine_name) = 0 THEN 'Шахта'
        WHEN GROUPING(s.shift_name) = 0 THEN 'Смена'
        WHEN GROUPING(et.type_name) = 0 THEN 'Тип оборудования'
        ELSE 'ИТОГО'
    END AS dimension,
    COALESCE(m.mine_name, s.shift_name, et.type_name, 'Все') AS dimension_value,
    SUM(fp.tons_mined) AS total_tons,
    SUM(fp.trips_count) AS total_trips,
    ROUND(SUM(fp.tons_mined) / NULLIF(SUM(fp.trips_count), 0), 2) AS avg_tons_per_trip
FROM fact_production fp
JOIN dim_mine m
    ON m.mine_id = fp.mine_id
JOIN dim_shift s
    ON s.shift_id = fp.shift_id
JOIN dim_equipment e
    ON e.equipment_id = fp.equipment_id
JOIN dim_equipment_type et
    ON et.equipment_type_id = e.equipment_type_id
WHERE fp.date_id BETWEEN 20240101 AND 20240131
GROUP BY GROUPING SETS (
    (m.mine_name),
    (s.shift_name),
    (et.type_name),
    ()
)
ORDER BY dimension, dimension_value;

-- Задание 4. Условная агрегация - PIVOT
SELECT
    COALESCE(m.mine_name, 'ИТОГО') AS mine_name,
    ROUND(AVG(CASE WHEN d.month = 1 THEN oq.fe_content END)::NUMERIC, 2) AS "Янв",
    ROUND(AVG(CASE WHEN d.month = 2 THEN oq.fe_content END)::NUMERIC, 2) AS "Фев",
    ROUND(AVG(CASE WHEN d.month = 3 THEN oq.fe_content END)::NUMERIC, 2) AS "Мар",
    ROUND(AVG(CASE WHEN d.month = 4 THEN oq.fe_content END)::NUMERIC, 2) AS "Апр",
    ROUND(AVG(CASE WHEN d.month = 5 THEN oq.fe_content END)::NUMERIC, 2) AS "Май",
    ROUND(AVG(CASE WHEN d.month = 6 THEN oq.fe_content END)::NUMERIC, 2) AS "Июн",
    ROUND(AVG(oq.fe_content)::NUMERIC, 2) AS "Среднее за период"
FROM fact_ore_quality oq
JOIN dim_mine m
    ON m.mine_id = oq.mine_id
JOIN dim_date d
    ON d.date_id = oq.date_id
WHERE d.year = 2024
  AND d.month BETWEEN 1 AND 6
GROUP BY GROUPING SETS (
    (m.mine_name),
    ()
)
ORDER BY GROUPING(m.mine_name), m.mine_name;

-- Задание 5. crosstab - динамический разворот
CREATE EXTENSION IF NOT EXISTS tablefunc;

SELECT *
FROM crosstab(
    $$
    SELECT
        e.equipment_name,
        dr.reason_name,
        ROUND(SUM(fd.duration_min) / 60.0, 1) AS duration_hours
    FROM fact_equipment_downtime fd
    JOIN dim_equipment e
        ON e.equipment_id = fd.equipment_id
    JOIN dim_downtime_reason dr
        ON dr.reason_id = fd.reason_id
    WHERE fd.date_id BETWEEN 20240101 AND 20240331
    GROUP BY e.equipment_name, dr.reason_name
    ORDER BY e.equipment_name, dr.reason_name
    $$,
    $$
    SELECT dr.reason_name
    FROM fact_equipment_downtime fd
    JOIN dim_downtime_reason dr
        ON dr.reason_id = fd.reason_id
    WHERE fd.date_id BETWEEN 20240101 AND 20240331
    GROUP BY dr.reason_name
    ORDER BY SUM(fd.duration_min) DESC
    LIMIT 5
    $$
) AS ct (
    equipment_name TEXT,
    "Причина 1" NUMERIC,
    "Причина 2" NUMERIC,
    "Причина 3" NUMERIC,
    "Причина 4" NUMERIC,
    "Причина 5" NUMERIC
);

-- Задание 6. Комплексный отчёт - ROLLUP + PIVOT + тренд
WITH raw_report AS (
    SELECT
        m.mine_name,
        'Добыча (тонн)' AS metric,
        SUM(CASE WHEN d.month = 1 THEN fp.tons_mined END) AS jan,
        SUM(CASE WHEN d.month = 2 THEN fp.tons_mined END) AS feb,
        SUM(CASE WHEN d.month = 3 THEN fp.tons_mined END) AS mar,
        SUM(fp.tons_mined) AS q1_total,
        GROUPING(m.mine_name) AS is_total
    FROM fact_production fp
    JOIN dim_mine m
        ON m.mine_id = fp.mine_id
    JOIN dim_date d
        ON d.date_id = fp.date_id
    WHERE d.year = 2024
      AND d.quarter = 1
    GROUP BY ROLLUP(m.mine_name)

    UNION ALL

    SELECT
        m.mine_name,
        'Простои (часы)' AS metric,
        SUM(CASE WHEN d.month = 1 THEN fd.duration_min END) / 60.0 AS jan,
        SUM(CASE WHEN d.month = 2 THEN fd.duration_min END) / 60.0 AS feb,
        SUM(CASE WHEN d.month = 3 THEN fd.duration_min END) / 60.0 AS mar,
        SUM(fd.duration_min) / 60.0 AS q1_total,
        GROUPING(m.mine_name) AS is_total
    FROM fact_equipment_downtime fd
    JOIN dim_equipment e
        ON e.equipment_id = fd.equipment_id
    JOIN dim_mine m
        ON m.mine_id = e.mine_id
    JOIN dim_date d
        ON d.date_id = fd.date_id
    WHERE d.year = 2024
      AND d.quarter = 1
    GROUP BY ROLLUP(m.mine_name)
)
SELECT
    CASE WHEN is_total = 1 THEN 'ИТОГО' ELSE mine_name END AS "Шахта",
    metric AS "Метрика",
    ROUND(jan, 1) AS "Январь",
    ROUND(feb, 1) AS "Февраль",
    ROUND(mar, 1) AS "Март",
    ROUND(q1_total, 1) AS "Q1 Итого",
    CASE
        WHEN jan > 0 THEN ROUND((feb - jan) / jan * 100, 1)
        ELSE 0
    END AS "Изменение Фев vs Янв (%)",
    CASE
        WHEN feb > 0 THEN ROUND((mar - feb) / feb * 100, 1)
        ELSE 0
    END AS "Изменение Мар vs Фев (%)",
    CASE
        WHEN feb = 0 THEN 'нет данных'
        WHEN (mar - feb) / feb * 100 > 5 THEN 'рост'
        WHEN (mar - feb) / feb * 100 < -5 THEN 'снижение'
        ELSE 'стабильно'
    END AS "Тренд"
FROM raw_report
ORDER BY metric, is_total, mine_name;
