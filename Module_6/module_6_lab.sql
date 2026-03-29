-- Лабораторная работа - Модуль 6

-- Задание 1. Округление результатов анализов (математические функции)
SELECT 
    sample_number,
    ROUND(fe_content, 1) AS fe_rounded,
    CEIL(sio2_content) AS sio2_ceil,
    FLOOR(al2o3_content) AS al2o3_floor
FROM fact_ore_quality
WHERE date_id = 20240315
ORDER BY fe_content DESC;

-- Задание 2. Отклонение от целевого содержания Fe (ABS, SIGN, POWER)
SELECT 
    sample_number,
    fe_content,
    ROUND(fe_content - 60, 2) AS deviation,
    ROUND(ABS(fe_content - 60), 2) AS abs_deviation,
    CASE SIGN(fe_content - 60)
        WHEN 1 THEN 'Выше нормы'
        WHEN 0 THEN 'В норме'
        WHEN -1 THEN 'Ниже нормы'
    END AS direction,
    ROUND(POWER(fe_content - 60, 2), 2) AS squared_dev
FROM fact_ore_quality
WHERE date_id BETWEEN 20240301 AND 20240331
ORDER BY abs_deviation DESC
LIMIT 10;

-- Задание 3. Статистика добычи по сменам (агрегатные функции)
SELECT 
    fp.shift_id,
    CASE fp.shift_id
        WHEN 1 THEN 'Утренняя'
        WHEN 2 THEN 'Дневная'
        WHEN 3 THEN 'Ночная'
    END AS shift_name,
    COUNT(*) AS record_count,
    SUM(fp.tons_mined) AS total_tons,
    ROUND(AVG(fp.tons_mined), 2) AS avg_tons,
    COUNT(DISTINCT fp.operator_id) AS unique_operators
FROM fact_production fp
WHERE fp.date_id BETWEEN 20240301 AND 20240331
GROUP BY fp.shift_id
ORDER BY fp.shift_id;

-- Задание 4. Список причин простоев по оборудованию (STRING_AGG)
SELECT 
    e.equipment_name,
    STRING_AGG(DISTINCT dr.reason_name, '; ' ORDER BY dr.reason_name) AS reasons,
    SUM(fd.duration_min) AS total_min,
    COUNT(*) AS incidents
FROM fact_equipment_downtime fd
JOIN dim_equipment e ON fd.equipment_id = e.equipment_id
JOIN dim_downtime_reason dr ON fd.reason_id = dr.reason_id
WHERE fd.date_id BETWEEN 20240301 AND 20240331
GROUP BY e.equipment_name
ORDER BY total_min DESC;

-- Задание 5. Преобразование date_id и форматирование отчёта (CAST, TO_CHAR)
SELECT 
    fp.date_id,
    TO_CHAR(TO_DATE(fp.date_id::VARCHAR, 'YYYYMMDD'), 'DD.MM.YYYY') AS formatted_date,
    SUM(fp.tons_mined) AS total_tons,
    TO_CHAR(SUM(fp.tons_mined), 'FM999G999D00') AS formatted_tons
FROM fact_production fp
WHERE fp.date_id BETWEEN 20240301 AND 20240307
GROUP BY fp.date_id
ORDER BY fp.date_id;

-- Задание 6. Классификация проб и расчёт процента качества (CASE, COALESCE, NULLIF)
SELECT 
    d.full_date,
    SUM(CASE WHEN oq.fe_content >= 65 THEN 1 ELSE 0 END) AS rich_ore,
    SUM(CASE WHEN oq.fe_content >= 55 AND oq.fe_content < 65 THEN 1 ELSE 0 END) AS medium_ore,
    SUM(CASE WHEN oq.fe_content < 55 THEN 1 ELSE 0 END) AS poor_ore,
    COUNT(*) AS total,
    ROUND(100.0 * SUM(CASE WHEN oq.fe_content >= 60 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS good_pct
FROM fact_ore_quality oq
JOIN dim_date d ON oq.date_id = d.date_id
WHERE d.year = 2024 AND d.month = 3
GROUP BY d.full_date
ORDER BY d.full_date;

-- Задание 7. Безопасные KPI с обработкой NULL и нуля (COALESCE, NULLIF, GREATEST)
SELECT 
    o.last_name || ' ' || o.first_name AS operator_name,
    SUM(fp.tons_mined) AS total_tons,
    COALESCE(SUM(fp.fuel_consumed_l), 0) AS total_fuel,
    ROUND(SUM(fp.tons_mined) / NULLIF(SUM(fp.trips_count), 0), 2) AS tons_per_trip,
    ROUND(COALESCE(SUM(fp.fuel_consumed_l), 0) / NULLIF(SUM(fp.tons_mined), 0), 3) AS fuel_per_ton,
    GREATEST(
        ROUND(SUM(fp.tons_mined) FILTER (WHERE fp.shift_id = 1) / NULLIF(SUM(fp.trips_count) FILTER (WHERE fp.shift_id = 1), 0), 2),
        ROUND(SUM(fp.tons_mined) FILTER (WHERE fp.shift_id = 2) / NULLIF(SUM(fp.trips_count) FILTER (WHERE fp.shift_id = 2), 0), 2)
    ) AS max_efficiency
FROM fact_production fp
JOIN dim_operator o ON fp.operator_id = o.operator_id
WHERE fp.date_id BETWEEN 20240301 AND 20240331
GROUP BY o.last_name, o.first_name
ORDER BY tons_per_trip DESC;

-- Задание 8. Анализ пропусков данных (IS NULL, COUNT, CASE)
SELECT 
    COUNT(*) AS total_rows,
    COUNT(sio2_content) AS sio2_filled,
    COUNT(*) - COUNT(sio2_content) AS sio2_null,
    ROUND(100.0 * COUNT(sio2_content) / COUNT(*), 1) AS sio2_pct,
    COUNT(al2o3_content) AS al2o3_filled,
    COUNT(*) - COUNT(al2o3_content) AS al2o3_null,
    ROUND(100.0 * COUNT(al2o3_content) / COUNT(*), 1) AS al2o3_pct,
    COUNT(moisture) AS moisture_filled,
    COUNT(*) - COUNT(moisture) AS moisture_null,
    ROUND(100.0 * COUNT(moisture) / COUNT(*), 1) AS moisture_pct,
    COUNT(density) AS density_filled,
    COUNT(*) - COUNT(density) AS density_null,
    ROUND(100.0 * COUNT(density) / COUNT(*), 1) AS density_pct,
    COUNT(sample_weight_kg) AS weight_filled,
    COUNT(*) - COUNT(sample_weight_kg) AS weight_null,
    ROUND(100.0 * COUNT(sample_weight_kg) / COUNT(*), 1) AS weight_pct
FROM fact_ore_quality
WHERE date_id BETWEEN 20240301 AND 20240331;

-- Задание 9. Комплексный отчёт по эффективности оборудования
SELECT 
    e.equipment_name,
    et.type_name,
    COUNT(fp.production_id) AS shift_count,
    ROUND(SUM(fp.tons_mined), 1) AS total_tons,
    ROUND(SUM(fp.operating_hours), 1) AS total_hours,
    ROUND(SUM(fp.tons_mined) / NULLIF(SUM(fp.operating_hours), 0), 2) AS productivity,
    ROUND(100.0 * SUM(fp.operating_hours) / NULLIF(COUNT(fp.production_id) * 8.0, 0), 1) AS utilization_pct,
    ROUND(COALESCE(SUM(fp.fuel_consumed_l), 0) / NULLIF(SUM(fp.tons_mined), 0), 3) AS fuel_per_ton,
    CASE 
        WHEN ROUND(SUM(fp.tons_mined) / NULLIF(SUM(fp.operating_hours), 0), 2) > 20 THEN 'Высокая'
        WHEN ROUND(SUM(fp.tons_mined) / NULLIF(SUM(fp.operating_hours), 0), 2) > 12 THEN 'Средняя'
        ELSE 'Низкая'
    END AS efficiency_category,
    CASE 
        WHEN COUNT(fp.fuel_consumed_l) = COUNT(*) THEN 'Полные'
        ELSE 'Неполные'
    END AS data_status
FROM fact_production fp
JOIN dim_equipment e ON fp.equipment_id = e.equipment_id
JOIN dim_equipment_type et ON e.equipment_type_id = et.equipment_type_id
WHERE fp.date_id BETWEEN 20240301 AND 20240331
GROUP BY e.equipment_name, et.type_name
ORDER BY productivity DESC;

-- Задание 10. Категоризация простоев (все функции модуля)
WITH categorized AS (
    SELECT 
        e.equipment_name,
        dr.reason_name,
        COALESCE(fd.duration_min, 0) AS duration_safe,
        CASE 
            WHEN COALESCE(fd.duration_min, 0) > 480 THEN 'Критический'
            WHEN COALESCE(fd.duration_min, 0) >= 120 THEN 'Длительный'
            WHEN COALESCE(fd.duration_min, 0) >= 30 THEN 'Средний'
            ELSE 'Короткий'
        END AS duration_category,
        CASE 
            WHEN fd.is_planned THEN 'Плановый'
            ELSE 'Внеплановый'
        END AS planned_status,
        CASE 
            WHEN fd.end_time IS NULL THEN 'В процессе'
            ELSE 'Завершён'
        END AS completion_status
    FROM fact_equipment_downtime fd
    JOIN dim_equipment e ON fd.equipment_id = e.equipment_id
    JOIN dim_downtime_reason dr ON fd.reason_id = dr.reason_id
    WHERE fd.date_id BETWEEN 20240301 AND 20240331
)
SELECT 
    duration_category,
    COUNT(*) AS downtime_count,
    ROUND(SUM(duration_safe) / 60.0, 1) AS total_hours,
    ROUND(100.0 * SUM(duration_safe) / NULLIF(SUM(SUM(duration_safe)) OVER (), 0), 1) AS pct_of_total
FROM categorized
GROUP BY duration_category
ORDER BY total_hours DESC;
