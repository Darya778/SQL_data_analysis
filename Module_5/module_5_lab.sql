-- Лабораторная работа - Модуль 5
-- Использование DML для изменения данных

-- Задание 1. Добавление нового оборудования
SELECT *
FROM practice_dim_equipment
WHERE equipment_id = 200;

INSERT INTO practice_dim_equipment (
    equipment_id,
    equipment_type_id,
    mine_id,
    equipment_name,
    inventory_number,
    manufacturer,
    model,
    year_manufactured,
    commissioning_date,
    status,
    has_video_recorder,
    has_navigation
)
VALUES (
    200,
    2,
    2,
    'Самосвал МоАЗ-7529',
    'INV-TRK-200',
    'МоАЗ',
    '7529',
    2025,
    DATE '2025-03-15',
    'active',
    TRUE,
    TRUE
);

SELECT *
FROM practice_dim_equipment
WHERE equipment_id = 200;

-- Задание 2. Массовая вставка операторов
SELECT *
FROM practice_dim_operator
WHERE operator_id >= 200
ORDER BY operator_id;

INSERT INTO practice_dim_operator (
    operator_id,
    tab_number,
    last_name,
    first_name,
    middle_name,
    position,
    qualification,
    hire_date,
    mine_id
)
VALUES
    (200, 'TAB-200', 'Сидоров', 'Михаил', 'Иванович', 'Машинист ПДМ', '4 разряд', DATE '2025-03-01', 1),
    (201, 'TAB-201', 'Петрова', 'Елена', 'Сергеевна', 'Оператор скипа', '3 разряд', DATE '2025-03-01', 2),
    (202, 'TAB-202', 'Волков', 'Дмитрий', 'Алексеевич', 'Водитель самосвала', '5 разряд', DATE '2025-03-10', 2);

SELECT *
FROM practice_dim_operator
WHERE operator_id >= 200
ORDER BY operator_id;

-- Задание 3. Загрузка из staging
SELECT COUNT(*) AS before_count
FROM practice_fact_production;

INSERT INTO practice_fact_production (
    production_id,
    date_id,
    shift_id,
    equipment_id,
    operator_id,
    tons_mined,
    trips_count,
    fuel_consumed_l,
    operating_hours
)
SELECT
    3000 + sp.staging_id AS production_id,
    sp.date_id,
    sp.shift_id,
    sp.equipment_id,
    sp.operator_id,
    sp.tons_mined,
    sp.trips_count,
    sp.fuel_consumed_l,
    sp.operating_hours
FROM staging_production sp
WHERE sp.is_validated = TRUE
  AND NOT EXISTS (
      SELECT 1
      FROM practice_fact_production p
      WHERE p.date_id = sp.date_id
        AND p.shift_id = sp.shift_id
        AND p.equipment_id = sp.equipment_id
        AND p.operator_id = sp.operator_id
  );

SELECT COUNT(*) AS after_count
FROM practice_fact_production;

-- Задание 4. INSERT ... RETURNING с логированием
WITH ins_grade AS (
    INSERT INTO practice_dim_ore_grade (
        ore_grade_id,
        grade_name,
        grade_code,
        fe_content_min,
        fe_content_max,
        description
    )
    VALUES (
        300,
        'Экспортный',
        'EXPORT',
        63.00,
        68.00,
        'Руда для экспортных поставок'
    )
    RETURNING ore_grade_id, grade_name, grade_code
)
INSERT INTO practice_equipment_log (
    equipment_id,
    action,
    details
)
SELECT
    0,
    'INSERT',
    'Добавлен сорт руды: ' || grade_name || ' (' || grade_code || ')'
FROM ins_grade;

SELECT *
FROM practice_dim_ore_grade
WHERE ore_grade_id = 300;

SELECT *
FROM practice_equipment_log
WHERE equipment_id = 0
ORDER BY log_id DESC;

-- Задание 5. Обновление статуса оборудования
WITH updated_rows AS (
    UPDATE practice_dim_equipment
    SET status = 'maintenance'
    WHERE mine_id = 1
      AND year_manufactured <= 2018
    RETURNING equipment_id, equipment_name, year_manufactured, status
)
SELECT *
FROM updated_rows
ORDER BY year_manufactured, equipment_id;

SELECT
    equipment_id,
    equipment_name,
    year_manufactured,
    status
FROM practice_dim_equipment
WHERE status = 'maintenance'
ORDER BY year_manufactured, equipment_id;

-- Задание 6. UPDATE с подзапросом
UPDATE practice_dim_equipment e
SET has_navigation = TRUE
WHERE e.has_navigation = FALSE
  AND e.equipment_id IN (
      SELECT DISTINCT s.equipment_id
      FROM dim_sensor s
      JOIN dim_sensor_type st
        ON s.sensor_type_id = st.sensor_type_id
      WHERE st.type_code = 'NAV'
        AND s.status = 'active'
  );

SELECT
    equipment_id,
    equipment_name,
    has_navigation
FROM practice_dim_equipment
WHERE has_navigation = TRUE
ORDER BY equipment_id;

-- Задание 7. DELETE с условием и архивированием
WITH deleted_rows AS (
    DELETE FROM practice_fact_telemetry
    WHERE date_id = 20240315
      AND is_alarm = TRUE
    RETURNING *
)
INSERT INTO practice_archive_telemetry (
    telemetry_id,
    date_id,
    time_id,
    equipment_id,
    sensor_id,
    sensor_value,
    quality_flag,
    is_alarm
)
SELECT
    telemetry_id,
    date_id,
    time_id,
    equipment_id,
    sensor_id,
    sensor_value,
    quality_flag,
    is_alarm
FROM deleted_rows;

SELECT COUNT(*) AS active_alarm_rows
FROM practice_fact_telemetry
WHERE date_id = 20240315
  AND is_alarm = TRUE;

SELECT COUNT(*) AS archived_rows
FROM practice_archive_telemetry
WHERE date_id = 20240315
  AND is_alarm = TRUE;

-- Задание 8. MERGE — синхронизация справочника
SELECT *
FROM practice_dim_downtime_reason
ORDER BY reason_code;

SELECT *
FROM staging_downtime_reasons
ORDER BY reason_code;

WITH src AS (
    SELECT
        s.reason_code,
        s.reason_name,
        s.category,
        s.description,
        (SELECT COALESCE(MAX(reason_id), 0) FROM practice_dim_downtime_reason)
        + ROW_NUMBER() OVER (ORDER BY s.reason_code) AS new_reason_id
    FROM staging_downtime_reasons s
)
MERGE INTO practice_dim_downtime_reason AS tgt
USING src
ON tgt.reason_code = src.reason_code
WHEN MATCHED THEN
    UPDATE SET
        reason_name = src.reason_name,
        category = src.category,
        description = src.description
WHEN NOT MATCHED THEN
    INSERT (
        reason_id,
        reason_code,
        reason_name,
        category,
        description
    )
    VALUES (
        src.new_reason_id,
        src.reason_code,
        src.reason_name,
        src.category,
        src.description
    );

SELECT *
FROM practice_dim_downtime_reason
ORDER BY reason_code;

-- Задание 9. UPSERT — идемпотентная загрузка
INSERT INTO practice_dim_operator (
    operator_id,
    tab_number,
    last_name,
    first_name,
    middle_name,
    position,
    qualification,
    hire_date,
    mine_id
)
VALUES
    (200, 'TAB-200', 'Сидоров', 'Михаил', 'Иванович', 'Старший машинист ПДМ', '5 разряд', DATE '2025-03-01', 1),
    (201, 'TAB-201', 'Петрова', 'Елена', 'Сергеевна', 'Старший оператор скипа', '4 разряд', DATE '2025-03-01', 2),
    (203, 'TAB-NEW', 'Орлов', 'Игорь', 'Павлович', 'Оператор конвейера', '3 разряд', DATE '2025-03-20', 1)
ON CONFLICT (tab_number)
DO UPDATE SET
    position = EXCLUDED.position,
    qualification = EXCLUDED.qualification;

SELECT
    operator_id,
    tab_number,
    last_name,
    first_name,
    position,
    qualification
FROM practice_dim_operator
WHERE tab_number IN ('TAB-200', 'TAB-201', 'TAB-NEW')
ORDER BY tab_number;
