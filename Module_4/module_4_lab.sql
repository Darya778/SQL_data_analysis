-- Лабораторная работа - Модуль 4

-- Задание 1. Анализ длины строковых полей
SELECT 
    equipment_name,
    LENGTH(equipment_name) AS name_length,
    LENGTH(inventory_number) AS inv_length,
    LENGTH(model) AS model_length,
    LENGTH(manufacturer) AS manuf_length,
    COALESCE(LENGTH(equipment_name), 0) + 
    COALESCE(LENGTH(inventory_number), 0) + 
    COALESCE(LENGTH(model), 0) + 
    COALESCE(LENGTH(manufacturer), 0) AS total_text_length
FROM dim_equipment
ORDER BY total_text_length DESC;

-- Задание 2. Разбор инвентарного номера
SELECT 
    equipment_name,
    inventory_number,
    SPLIT_PART(inventory_number, '-', 1) AS prefix,
    SPLIT_PART(inventory_number, '-', 2) AS type_code,
    CAST(SPLIT_PART(inventory_number, '-', 3) AS INTEGER) AS serial_number,
    CASE SPLIT_PART(inventory_number, '-', 2)
        WHEN 'LHD' THEN 'Погрузочно-доставочная машина'
        WHEN 'TRUCK' THEN 'Шахтный самосвал'
        WHEN 'CART' THEN 'Вагонетка'
        WHEN 'SKIP' THEN 'Скиповой подъёмник'
        ELSE 'Неизвестный тип'
    END AS type_description
FROM dim_equipment
ORDER BY type_code, serial_number;

-- Задание 3. Формирование краткого имени оператора
SELECT 
    last_name,
    first_name,
    middle_name,
    CONCAT(last_name, ' ', 
           LEFT(first_name, 1), '.',
           CASE 
               WHEN middle_name IS NOT NULL AND middle_name != '' 
               THEN LEFT(middle_name, 1) || '.'
               ELSE ''
           END) AS short_name_1,
    CONCAT(LEFT(first_name, 1), '.',
           CASE 
               WHEN middle_name IS NOT NULL AND middle_name != '' 
               THEN LEFT(middle_name, 1) || '. '
               ELSE ' '
           END,
           UPPER(last_name)) AS short_name_2,
    UPPER(last_name) AS upper_last_name,
    LOWER(position) AS lower_position
FROM dim_operator
ORDER BY last_name;

-- Задание 4. Поиск оборудования по шаблону
-- 4.1: Оборудование с "ПДМ" в названии
SELECT equipment_name, inventory_number, model
FROM dim_equipment
WHERE equipment_name LIKE '%ПДМ%';
-- 4.2: Производители на "S" (латинская) без учёта регистра
SELECT equipment_name, manufacturer, model
FROM dim_equipment
WHERE manufacturer ILIKE 'S%';
-- 4.3: Шахты с кавычками в названии
SELECT mine_name
FROM dim_mine
WHERE mine_name LIKE '%"%';
-- 4.4: Инвентарные номера с серийной частью от 001 до 010 (регулярное выражение)
SELECT inventory_number, equipment_name
FROM dim_equipment
WHERE inventory_number ~ '^INV-[A-Z]+-(00[1-9]|010)$';

-- Задание 5. Список оборудования по шахтам (STRING_AGG)
SELECT 
    m.mine_name,
    COUNT(e.equipment_id) AS equipment_count,
    STRING_AGG(e.equipment_name, ', ' ORDER BY e.equipment_name) AS equipment_list,
    STRING_AGG(DISTINCT e.manufacturer, '; ' ORDER BY e.manufacturer) AS unique_manufacturers
FROM dim_equipment e
JOIN dim_mine m ON e.mine_id = m.mine_id
GROUP BY m.mine_name
ORDER BY m.mine_name;

-- Задание 6. Возраст оборудования
SELECT 
    equipment_name,
    commissioning_date,
    AGE(CURRENT_DATE, commissioning_date) AS age_full,
    EXTRACT(YEAR FROM AGE(CURRENT_DATE, commissioning_date)) AS years,
    EXTRACT(DAY FROM AGE(CURRENT_DATE, commissioning_date)) AS days,
    CASE 
        WHEN EXTRACT(YEAR FROM AGE(CURRENT_DATE, commissioning_date)) < 2 THEN 'Новое'
        WHEN EXTRACT(YEAR FROM AGE(CURRENT_DATE, commissioning_date)) <= 4 THEN 'Рабочее'
        ELSE 'Требует внимания'
    END AS category
FROM dim_equipment
WHERE commissioning_date IS NOT NULL
ORDER BY days DESC;

-- Задание 7. Форматирование дат для отчётов
SELECT 
    equipment_name,
    commissioning_date,
    TO_CHAR(commissioning_date, 'DD.MM.YYYY') AS russian_format,
    TO_CHAR(commissioning_date, 'DD Month YYYY') || ' г.' AS full_format,
    TO_CHAR(commissioning_date, 'YYYY-MM-DD') AS iso_format,
    TO_CHAR(commissioning_date, 'YYYY-"Q"Q') AS year_quarter,
    TO_CHAR(commissioning_date, 'Day') AS day_of_week,
    TO_CHAR(commissioning_date, 'YYYY-MM') AS year_month
FROM dim_equipment
WHERE commissioning_date IS NOT NULL
ORDER BY commissioning_date;

-- Задание 8. Анализ простоев по дням недели и часам
-- 8.1: Анализ по дням недели
SELECT 
    CASE EXTRACT(DOW FROM start_time)
        WHEN 0 THEN 'Воскресенье'
        WHEN 1 THEN 'Понедельник'
        WHEN 2 THEN 'Вторник'
        WHEN 3 THEN 'Среда'
        WHEN 4 THEN 'Четверг'
        WHEN 5 THEN 'Пятница'
        WHEN 6 THEN 'Суббота'
    END AS day_of_week,
    COUNT(*) AS downtime_count,
    ROUND(AVG(duration_min), 1) AS avg_duration_min,
    EXTRACT(DOW FROM start_time) AS dow_number
FROM fact_equipment_downtime
GROUP BY EXTRACT(DOW FROM start_time)
ORDER BY dow_number;
-- 8.2: Анализ по часам
SELECT 
    EXTRACT(HOUR FROM start_time) AS hour_of_day,
    COUNT(*) AS downtime_count,
    ROUND(AVG(duration_min), 1) AS avg_duration_min
FROM fact_equipment_downtime
GROUP BY EXTRACT(HOUR FROM start_time)
ORDER BY hour_of_day;
-- 8.3: Пиковый час (час с наибольшим количеством простоев)
SELECT 
    EXTRACT(HOUR FROM start_time) AS peak_hour,
    COUNT(*) AS downtime_count
FROM fact_equipment_downtime
GROUP BY EXTRACT(HOUR FROM start_time)
ORDER BY downtime_count DESC
LIMIT 1;
-- 8.4: Группировка по часам с DATE_TRUNC
SELECT 
    DATE_TRUNC('hour', start_time) AS hour_bucket,
    COUNT(*) AS downtime_count,
    ROUND(AVG(duration_min), 1) AS avg_duration_min
FROM fact_equipment_downtime
GROUP BY DATE_TRUNC('hour', start_time)
ORDER BY hour_bucket;

-- Задание 9. Расчёт графика калибровки датчиков
SELECT 
    s.sensor_code,
    st.type_name AS sensor_type,
    e.equipment_name,
    s.calibration_date,
    EXTRACT(DAY FROM AGE(CURRENT_DATE, s.calibration_date)) AS days_since_last_calibration,
    s.calibration_date + INTERVAL '180 days' AS next_calibration_date,
    CASE 
        WHEN EXTRACT(DAY FROM AGE(CURRENT_DATE, s.calibration_date)) > 180 THEN 'Просрочена'
        WHEN EXTRACT(DAY FROM AGE(CURRENT_DATE, s.calibration_date)) > 150 THEN 'Скоро'
        ELSE 'В норме'
    END AS status
FROM dim_sensor s
JOIN dim_sensor_type st ON s.sensor_type_id = st.sensor_type_id
JOIN dim_equipment e ON s.equipment_id = e.equipment_id
WHERE s.calibration_date IS NOT NULL
ORDER BY 
    CASE 
        WHEN EXTRACT(DAY FROM AGE(CURRENT_DATE, s.calibration_date)) > 180 THEN 1
        WHEN EXTRACT(DAY FROM AGE(CURRENT_DATE, s.calibration_date)) > 150 THEN 2
        ELSE 3
    END,
    s.calibration_date;

-- Задание 10. Комплексный отчёт: карточка оборудования
SELECT 
    CONCAT(
        '[', UPPER(et.type_name), '] ',
        e.equipment_name,
        ' (', e.manufacturer, ' ', COALESCE(e.model, ''), ')',
        ' | Шахта: ', m.mine_name,
        ' | Введён: ', TO_CHAR(e.commissioning_date, 'DD.MM.YYYY'),
        ' | Возраст: ', 
            EXTRACT(YEAR FROM AGE(CURRENT_DATE, e.commissioning_date))::TEXT, 
            ' лет',
        ' | Статус: ', 
            CASE e.status
                WHEN 'active' THEN 'АКТИВЕН'
                WHEN 'maintenance' THEN 'НА ТО'
                WHEN 'decommissioned' THEN 'СПИСАН'
                ELSE UPPER(e.status)
            END,
        ' | Видеорег.: ', CASE WHEN e.has_video_recorder THEN 'ДА' ELSE 'НЕТ' END,
        ' | Навигация: ', CASE WHEN e.has_navigation THEN 'ДА' ELSE 'НЕТ' END
    ) AS equipment_card
FROM dim_equipment e
JOIN dim_equipment_type et ON e.equipment_type_id = et.equipment_type_id
JOIN dim_mine m ON e.mine_id = m.mine_id
WHERE e.commissioning_date IS NOT NULL
ORDER BY e.equipment_name;
