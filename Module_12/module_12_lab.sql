-- Лабораторная работа - Модуль 12
-- Использование операторов набора

-- Задание 1. UNION ALL — объединённый журнал событий
SELECT
    'Добыча' AS event_type,
    e.equipment_name,
    fp.tons_mined AS value,
    'тонн' AS unit
FROM fact_production fp
JOIN dim_equipment e
    ON e.equipment_id = fp.equipment_id
WHERE fp.date_id = 20240315

UNION ALL

SELECT
    'Простой' AS event_type,
    e.equipment_name,
    fd.duration_min AS value,
    'мин.' AS unit
FROM fact_equipment_downtime fd
JOIN dim_equipment e
    ON e.equipment_id = fd.equipment_id
WHERE fd.date_id = 20240315

ORDER BY equipment_name, event_type;

-- Задание 2. UNION — уникальные шахты с активностью
WITH active_mines AS (
    SELECT fp.mine_id
    FROM fact_production fp
    WHERE fp.date_id BETWEEN 20240101 AND 20240331

    UNION

    SELECT e.mine_id
    FROM fact_equipment_downtime fd
    JOIN dim_equipment e
        ON e.equipment_id = fd.equipment_id
    WHERE fd.date_id BETWEEN 20240101 AND 20240331
)
SELECT
    m.mine_id,
    m.mine_name
FROM active_mines am
JOIN dim_mine m
    ON m.mine_id = am.mine_id
ORDER BY m.mine_name;

SELECT COUNT(*) AS unique_mines_count
FROM (
    SELECT fp.mine_id
    FROM fact_production fp
    WHERE fp.date_id BETWEEN 20240101 AND 20240331

    UNION

    SELECT e.mine_id
    FROM fact_equipment_downtime fd
    JOIN dim_equipment e
        ON e.equipment_id = fd.equipment_id
    WHERE fd.date_id BETWEEN 20240101 AND 20240331
) active_mines;

-- Задание 3. EXCEPT — оборудование без данных о качестве
WITH production_equipment AS (
    SELECT DISTINCT fp.equipment_id
    FROM fact_production fp
    WHERE fp.date_id BETWEEN 20240101 AND 20240331
),
quality_equipment AS (
    SELECT DISTINCT fp.equipment_id
    FROM fact_ore_quality fq
    JOIN fact_production fp
        ON fp.mine_id = fq.mine_id
       AND fp.shaft_id = fq.shaft_id
       AND fp.date_id = fq.date_id
    WHERE fq.date_id BETWEEN 20240101 AND 20240331
)
SELECT
    e.equipment_name,
    et.type_name
FROM (
    SELECT equipment_id
    FROM production_equipment

    EXCEPT

    SELECT equipment_id
    FROM quality_equipment
) diff_equipment
JOIN dim_equipment e
    ON e.equipment_id = diff_equipment.equipment_id
JOIN dim_equipment_type et
    ON et.equipment_type_id = e.equipment_type_id
ORDER BY e.equipment_name;

-- Альтернатива через NOT EXISTS
SELECT
    e.equipment_name,
    et.type_name
FROM (
    SELECT DISTINCT fp.equipment_id
    FROM fact_production fp
    WHERE fp.date_id BETWEEN 20240101 AND 20240331
) production_equipment
JOIN dim_equipment e
    ON e.equipment_id = production_equipment.equipment_id
JOIN dim_equipment_type et
    ON et.equipment_type_id = e.equipment_type_id
WHERE NOT EXISTS (
    SELECT 1
    FROM fact_ore_quality fq
    JOIN fact_production fp2
        ON fp2.mine_id = fq.mine_id
       AND fp2.shaft_id = fq.shaft_id
       AND fp2.date_id = fq.date_id
    WHERE fq.date_id BETWEEN 20240101 AND 20240331
      AND fp2.equipment_id = production_equipment.equipment_id
)
ORDER BY e.equipment_name;

-- Задание 4. INTERSECT — операторы на нескольких типах оборудования
SELECT
    o.last_name || ' ' || LEFT(o.first_name, 1) || '.' AS operator_name,
    o.position,
    o.qualification
FROM (
    SELECT fp.operator_id
    FROM fact_production fp
    JOIN dim_equipment e
        ON e.equipment_id = fp.equipment_id
    JOIN dim_equipment_type et
        ON et.equipment_type_id = e.equipment_type_id
    WHERE et.type_code = 'LHD'

    INTERSECT

    SELECT fp.operator_id
    FROM fact_production fp
    JOIN dim_equipment e
        ON e.equipment_id = fp.equipment_id
    JOIN dim_equipment_type et
        ON et.equipment_type_id = e.equipment_type_id
    WHERE et.type_code = 'TRUCK'
) universal_ops
JOIN dim_operator o
    ON o.operator_id = universal_ops.operator_id
ORDER BY operator_name;

SELECT
    COUNT(*) AS universal_count,
    ROUND(100.0 * COUNT(*) / NULLIF((SELECT COUNT(DISTINCT operator_id) FROM fact_production), 0), 1) AS universal_percent
FROM (
    SELECT fp.operator_id
    FROM fact_production fp
    JOIN dim_equipment e
        ON e.equipment_id = fp.equipment_id
    JOIN dim_equipment_type et
        ON et.equipment_type_id = e.equipment_type_id
    WHERE et.type_code = 'LHD'

    INTERSECT

    SELECT fp.operator_id
    FROM fact_production fp
    JOIN dim_equipment e
        ON e.equipment_id = fp.equipment_id
    JOIN dim_equipment_type et
        ON et.equipment_type_id = e.equipment_type_id
    WHERE et.type_code = 'TRUCK'
) universal_ops;

-- Задание 5. Диаграмма Венна: комплексный анализ
WITH lhd_ops AS (
    SELECT DISTINCT fp.operator_id
    FROM fact_production fp
    JOIN dim_equipment e
        ON e.equipment_id = fp.equipment_id
    JOIN dim_equipment_type et
        ON et.equipment_type_id = e.equipment_type_id
    WHERE et.type_code = 'LHD'
),
truck_ops AS (
    SELECT DISTINCT fp.operator_id
    FROM fact_production fp
    JOIN dim_equipment e
        ON e.equipment_id = fp.equipment_id
    JOIN dim_equipment_type et
        ON et.equipment_type_id = e.equipment_type_id
    WHERE et.type_code = 'TRUCK'
),
total_ops AS (
    SELECT DISTINCT operator_id
    FROM fact_production
)
SELECT 'Оба типа' AS category, COUNT(*) AS operator_count,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM total_ops), 1) AS percent_of_total
FROM (
    SELECT operator_id FROM lhd_ops
    INTERSECT
    SELECT operator_id FROM truck_ops
) both_ops

UNION ALL

SELECT 'Только ПДМ' AS category, COUNT(*) AS operator_count,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM total_ops), 1) AS percent_of_total
FROM (
    SELECT operator_id FROM lhd_ops
    EXCEPT
    SELECT operator_id FROM truck_ops
) only_lhd

UNION ALL

SELECT 'Только самосвал' AS category, COUNT(*) AS operator_count,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM total_ops), 1) AS percent_of_total
FROM (
    SELECT operator_id FROM truck_ops
    EXCEPT
    SELECT operator_id FROM lhd_ops
) only_truck

ORDER BY category;

-- Задание 6. LATERAL — топ-5 простоев по каждой шахте
SELECT
    m.mine_name,
    top5.full_date,
    top5.equipment_name,
    top5.reason_name,
    top5.duration_min,
    ROUND(top5.duration_min / 60.0, 1) AS duration_hours
FROM dim_mine m
CROSS JOIN LATERAL (
    SELECT
        d.full_date,
        e.equipment_name,
        dr.reason_name,
        fd.duration_min
    FROM fact_equipment_downtime fd
    JOIN dim_equipment e
        ON e.equipment_id = fd.equipment_id
    JOIN dim_downtime_reason dr
        ON dr.reason_id = fd.reason_id
    JOIN dim_date d
        ON d.date_id = fd.date_id
    WHERE e.mine_id = m.mine_id
      AND fd.is_planned = FALSE
      AND fd.date_id BETWEEN 20240101 AND 20240331
    ORDER BY fd.duration_min DESC
    LIMIT 5
) top5
WHERE m.status = 'active'
ORDER BY m.mine_name, top5.duration_min DESC;

-- Задание 7. LEFT JOIN LATERAL — последнее показание датчика
SELECT
    s.sensor_code,
    st.type_name AS sensor_type,
    e.equipment_name,
    d.full_date AS last_reading_date,
    t.full_time AS last_reading_time,
    lt.sensor_value,
    lt.is_alarm
FROM dim_sensor s
JOIN dim_sensor_type st
    ON st.sensor_type_id = s.sensor_type_id
JOIN dim_equipment e
    ON e.equipment_id = s.equipment_id
LEFT JOIN LATERAL (
    SELECT
        ft.date_id,
        ft.time_id,
        ft.sensor_value,
        ft.is_alarm
    FROM fact_equipment_telemetry ft
    WHERE ft.sensor_id = s.sensor_id
    ORDER BY ft.date_id DESC, ft.time_id DESC
    LIMIT 1
) lt ON TRUE
LEFT JOIN dim_date d
    ON d.date_id = lt.date_id
LEFT JOIN dim_time t
    ON t.time_id = lt.time_id
WHERE s.status = 'active'
ORDER BY lt.date_id ASC NULLS FIRST, s.sensor_code;

-- Задание 8. UNION ALL + агрегация — сводный KPI-отчёт
WITH kpi AS (
    SELECT
        m.mine_name,
        'Добыча (тонн)' AS kpi_name,
        SUM(fp.tons_mined)::NUMERIC AS kpi_value
    FROM fact_production fp
    JOIN dim_mine m
        ON m.mine_id = fp.mine_id
    WHERE fp.date_id BETWEEN 20240301 AND 20240331
    GROUP BY m.mine_name

    UNION ALL

    SELECT
        m.mine_name,
        'Простои (часы)' AS kpi_name,
        ROUND(SUM(fd.duration_min) / 60.0, 1)::NUMERIC AS kpi_value
    FROM fact_equipment_downtime fd
    JOIN dim_equipment e
        ON e.equipment_id = fd.equipment_id
    JOIN dim_mine m
        ON m.mine_id = e.mine_id
    WHERE fd.date_id BETWEEN 20240301 AND 20240331
    GROUP BY m.mine_name

    UNION ALL

    SELECT
        m.mine_name,
        'Среднее Fe (%)' AS kpi_name,
        ROUND(AVG(fq.fe_content), 2)::NUMERIC AS kpi_value
    FROM fact_ore_quality fq
    JOIN dim_mine m
        ON m.mine_id = fq.mine_id
    WHERE fq.date_id BETWEEN 20240301 AND 20240331
    GROUP BY m.mine_name

    UNION ALL

    SELECT
        m.mine_name,
        'Тревожные показания' AS kpi_name,
        COUNT(*)::NUMERIC AS kpi_value
    FROM fact_equipment_telemetry ft
    JOIN dim_equipment e
        ON e.equipment_id = ft.equipment_id
    JOIN dim_mine m
        ON m.mine_id = e.mine_id
    WHERE ft.date_id BETWEEN 20240301 AND 20240331
      AND ft.is_alarm = TRUE
    GROUP BY m.mine_name
)
SELECT
    mine_name,
    kpi_name,
    kpi_value
FROM kpi
ORDER BY mine_name, kpi_name;

-- Широкая форма (разворот в таблицу)
WITH kpi AS (
    SELECT
        m.mine_name,
        'Добыча (тонн)' AS kpi_name,
        SUM(fp.tons_mined)::NUMERIC AS kpi_value
    FROM fact_production fp
    JOIN dim_mine m
        ON m.mine_id = fp.mine_id
    WHERE fp.date_id BETWEEN 20240301 AND 20240331
    GROUP BY m.mine_name

    UNION ALL

    SELECT
        m.mine_name,
        'Простои (часы)' AS kpi_name,
        ROUND(SUM(fd.duration_min) / 60.0, 1)::NUMERIC AS kpi_value
    FROM fact_equipment_downtime fd
    JOIN dim_equipment e
        ON e.equipment_id = fd.equipment_id
    JOIN dim_mine m
        ON m.mine_id = e.mine_id
    WHERE fd.date_id BETWEEN 20240301 AND 20240331
    GROUP BY m.mine_name

    UNION ALL

    SELECT
        m.mine_name,
        'Среднее Fe (%)' AS kpi_name,
        ROUND(AVG(fq.fe_content), 2)::NUMERIC AS kpi_value
    FROM fact_ore_quality fq
    JOIN dim_mine m
        ON m.mine_id = fq.mine_id
    WHERE fq.date_id BETWEEN 20240301 AND 20240331
    GROUP BY m.mine_name

    UNION ALL

    SELECT
        m.mine_name,
        'Тревожные показания' AS kpi_name,
        COUNT(*)::NUMERIC AS kpi_value
    FROM fact_equipment_telemetry ft
    JOIN dim_equipment e
        ON e.equipment_id = ft.equipment_id
    JOIN dim_mine m
        ON m.mine_id = e.mine_id
    WHERE ft.date_id BETWEEN 20240301 AND 20240331
      AND ft.is_alarm = TRUE
    GROUP BY m.mine_name
)
SELECT
    mine_name,
    MAX(CASE WHEN kpi_name = 'Добыча (тонн)' THEN kpi_value END) AS production_tons,
    MAX(CASE WHEN kpi_name = 'Простои (часы)' THEN kpi_value END) AS downtime_hours,
    MAX(CASE WHEN kpi_name = 'Среднее Fe (%)' THEN kpi_value END) AS avg_fe_percent,
    MAX(CASE WHEN kpi_name = 'Тревожные показания' THEN kpi_value END) AS alarm_count
FROM kpi
GROUP BY mine_name
ORDER BY mine_name;
