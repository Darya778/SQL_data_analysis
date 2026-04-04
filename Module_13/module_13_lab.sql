-- Лабораторная работа - Модуль 13

-- Задание 1. Доля оборудования в общей добыче
SELECT
    e.equipment_name,
    fp.tons_mined,
    SUM(fp.tons_mined) OVER () AS total_tons,
    ROUND(100.0 * fp.tons_mined / NULLIF(SUM(fp.tons_mined) OVER (), 0), 1) AS pct_of_total
FROM fact_production fp
JOIN dim_equipment e
    ON e.equipment_id = fp.equipment_id
WHERE fp.date_id = 20240115
  AND fp.shift_id = 1
ORDER BY fp.tons_mined DESC, e.equipment_name;

-- Задание 2. Нарастающий итог по шахтам
WITH daily AS (
    SELECT
        fp.mine_id,
        m.mine_name,
        d.full_date,
        SUM(fp.tons_mined) AS daily_tons
    FROM fact_production fp
    JOIN dim_date d
        ON d.date_id = fp.date_id
    JOIN dim_mine m
        ON m.mine_id = fp.mine_id
    WHERE d.year = 2024
      AND d.month = 1
    GROUP BY fp.mine_id, m.mine_name, d.full_date
)
SELECT
    mine_name,
    full_date,
    daily_tons,
    SUM(daily_tons) OVER (
        PARTITION BY mine_id
        ORDER BY full_date
    ) AS running_tons
FROM daily
ORDER BY mine_name, full_date;

-- Задание 3. Скользящее среднее расхода ГСМ
WITH daily AS (
    SELECT
        d.full_date,
        SUM(fp.fuel_consumed_l) AS daily_fuel
    FROM fact_production fp
    JOIN dim_date d
        ON d.date_id = fp.date_id
    WHERE fp.mine_id = 1
      AND d.year = 2024
      AND d.quarter = 1
    GROUP BY d.full_date
)
SELECT
    full_date,
    daily_fuel,
    ROUND(
        AVG(daily_fuel) OVER (
            ORDER BY full_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ),
        2
    ) AS ma_7,
    ROUND(
        AVG(daily_fuel) OVER (
            ORDER BY full_date
            ROWS BETWEEN 13 PRECEDING AND CURRENT ROW
        ),
        2
    ) AS ma_14
FROM daily
ORDER BY full_date;

-- Задание 4. Рейтинг операторов по типам оборудования
WITH stats AS (
    SELECT
        o.operator_id,
        CONCAT(
            o.last_name, ' ',
            LEFT(o.first_name, 1), '.',
            CASE
                WHEN o.middle_name IS NOT NULL AND o.middle_name <> ''
                    THEN LEFT(o.middle_name, 1) || '.'
                ELSE ''
            END
        ) AS operator_name,
        et.type_name,
        SUM(fp.tons_mined) AS total_tons
    FROM fact_production fp
    JOIN dim_date d
        ON d.date_id = fp.date_id
    JOIN dim_operator o
        ON o.operator_id = fp.operator_id
    JOIN dim_equipment e
        ON e.equipment_id = fp.equipment_id
    JOIN dim_equipment_type et
        ON et.equipment_type_id = e.equipment_type_id
    WHERE d.year = 2024
      AND d.month BETWEEN 1 AND 6
    GROUP BY o.operator_id, operator_name, et.type_name
),
ranked AS (
    SELECT
        operator_name,
        type_name,
        total_tons,
        RANK() OVER (
            PARTITION BY type_name
            ORDER BY total_tons DESC
        ) AS rnk,
        DENSE_RANK() OVER (
            PARTITION BY type_name
            ORDER BY total_tons DESC
        ) AS dense_rnk,
        NTILE(4) OVER (
            PARTITION BY type_name
            ORDER BY total_tons DESC
        ) AS quartile
    FROM stats
)
SELECT
    operator_name,
    type_name,
    total_tons,
    rnk,
    dense_rnk,
    quartile
FROM ranked
WHERE rnk <= 5
ORDER BY type_name, rnk, operator_name;

-- Задание 5. Сравнение дневной и ночной смены
WITH shift_daily AS (
    SELECT
        d.full_date,
        fp.shift_id,
        s.shift_name,
        SUM(fp.tons_mined) AS shift_tons
    FROM fact_production fp
    JOIN dim_date d
        ON d.date_id = fp.date_id
    JOIN dim_shift s
        ON s.shift_id = fp.shift_id
    WHERE fp.mine_id = 1
      AND d.year = 2024
      AND d.month = 1
    GROUP BY d.full_date, fp.shift_id, s.shift_name
)
SELECT
    full_date,
    shift_id,
    shift_name,
    shift_tons,
    LAG(shift_tons) OVER w_seq AS prev_shift_tons,
    ROUND(
        100.0 * shift_tons / NULLIF(SUM(shift_tons) OVER (PARTITION BY full_date), 0),
        1
    ) AS pct_of_day,
    ROUND(AVG(shift_tons) OVER w_ma7, 2) AS ma7_by_shift
FROM shift_daily
WINDOW
    w_seq AS (ORDER BY full_date, shift_id),
    w_ma7 AS (
        PARTITION BY shift_id
        ORDER BY full_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    )
ORDER BY full_date, shift_id;

-- Задание 6. Интервалы между внеплановыми простоями
WITH downtime_base AS (
    SELECT
        fd.equipment_id,
        e.equipment_name,
        d.full_date,
        r.reason_name,
        fd.duration_min,
        LAG(d.full_date) OVER (
            PARTITION BY fd.equipment_id
            ORDER BY d.full_date, fd.start_time, fd.downtime_id
        ) AS prev_downtime_date,
        LEAD(d.full_date) OVER (
            PARTITION BY fd.equipment_id
            ORDER BY d.full_date, fd.start_time, fd.downtime_id
        ) AS next_downtime_date
    FROM fact_equipment_downtime fd
    JOIN dim_equipment e
        ON e.equipment_id = fd.equipment_id
    JOIN dim_date d
        ON d.date_id = fd.date_id
    JOIN dim_downtime_reason r
        ON r.reason_id = fd.reason_id
    WHERE fd.is_planned = FALSE
),
enriched AS (
    SELECT
        equipment_id,
        equipment_name,
        full_date,
        reason_name,
        duration_min,
        prev_downtime_date,
        full_date - prev_downtime_date AS days_since_prev,
        next_downtime_date
    FROM downtime_base
)
SELECT
    equipment_name,
    full_date AS downtime_date,
    reason_name,
    duration_min,
    prev_downtime_date,
    days_since_prev,
    next_downtime_date,
    ROUND(
        AVG(days_since_prev) OVER (PARTITION BY equipment_id),
        2
    ) AS avg_days_between_failures
FROM enriched
ORDER BY equipment_name, downtime_date;

-- Задание 7. Обнаружение выбросов по Fe методом IQR
WITH base AS (
    SELECT
        fq.quality_id,
        fq.mine_id,
        m.mine_name,
        d.full_date,
        fq.sample_number,
        fq.fe_content
    FROM fact_ore_quality fq
    JOIN dim_date d
        ON d.date_id = fq.date_id
    JOIN dim_mine m
        ON m.mine_id = fq.mine_id
    WHERE d.year = 2024
      AND d.month BETWEEN 1 AND 6
),
quartiles AS (
    SELECT DISTINCT
        mine_id,
        mine_name,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY fe_content)
            OVER (PARTITION BY mine_id) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY fe_content)
            OVER (PARTITION BY mine_id) AS q3
    FROM base
),
marked AS (
    SELECT
        b.mine_name,
        b.full_date,
        b.sample_number,
        b.fe_content,
        CASE
            WHEN b.fe_content < q.q1 - 1.5 * (q.q3 - q.q1)
                THEN 'Выброс (низ)'
            WHEN b.fe_content > q.q3 + 1.5 * (q.q3 - q.q1)
                THEN 'Выброс (верх)'
            ELSE 'Норма'
        END AS outlier_status
    FROM base b
    JOIN quartiles q
        ON q.mine_id = b.mine_id
)
SELECT
    mine_name,
    full_date,
    sample_number,
    fe_content,
    outlier_status
FROM marked
WHERE outlier_status <> 'Норма'
ORDER BY mine_name, full_date, sample_number;

SELECT
    mine_name,
    COUNT(*) AS outlier_count
FROM (
    SELECT
        b.mine_name,
        CASE
            WHEN b.fe_content < q.q1 - 1.5 * (q.q3 - q.q1)
                THEN 'Выброс (низ)'
            WHEN b.fe_content > q.q3 + 1.5 * (q.q3 - q.q1)
                THEN 'Выброс (верх)'
            ELSE 'Норма'
        END AS outlier_status
    FROM (
        SELECT
            fq.mine_id,
            m.mine_name,
            fq.fe_content
        FROM fact_ore_quality fq
        JOIN dim_date d
            ON d.date_id = fq.date_id
        JOIN dim_mine m
            ON m.mine_id = fq.mine_id
        WHERE d.year = 2024
          AND d.month BETWEEN 1 AND 6
    ) b
    JOIN (
        SELECT DISTINCT
            mine_id,
            PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY fe_content)
                OVER (PARTITION BY mine_id) AS q1,
            PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY fe_content)
                OVER (PARTITION BY mine_id) AS q3
        FROM (
            SELECT
                fq.mine_id,
                fq.fe_content
            FROM fact_ore_quality fq
            JOIN dim_date d
                ON d.date_id = fq.date_id
            WHERE d.year = 2024
              AND d.month BETWEEN 1 AND 6
        ) t
    ) q
        ON q.mine_id = b.mine_id
) marked
WHERE outlier_status <> 'Норма'
GROUP BY mine_name
ORDER BY mine_name;

-- Задание 8. ТОП-3 рекордных дня для каждой единицы оборудования
WITH daily AS (
    SELECT
        fp.equipment_id,
        e.equipment_name,
        et.type_name,
        d.full_date,
        SUM(fp.tons_mined) AS daily_tons
    FROM fact_production fp
    JOIN dim_equipment e
        ON e.equipment_id = fp.equipment_id
    JOIN dim_equipment_type et
        ON et.equipment_type_id = e.equipment_type_id
    JOIN dim_date d
        ON d.date_id = fp.date_id
    WHERE d.year = 2024
    GROUP BY fp.equipment_id, e.equipment_name, et.type_name, d.full_date
),
ranked AS (
    SELECT
        equipment_name,
        type_name,
        full_date,
        daily_tons,
        ROW_NUMBER() OVER (
            PARTITION BY equipment_id
            ORDER BY daily_tons DESC, full_date
        ) AS record_num,
        MAX(daily_tons) OVER (
            PARTITION BY equipment_id
        ) AS top1_tons
    FROM daily
)
SELECT
    equipment_name,
    type_name,
    full_date,
    daily_tons,
    record_num,
    top1_tons - daily_tons AS diff_from_top1
FROM ranked
WHERE record_num <= 3
ORDER BY equipment_name, record_num;

-- Задание 9. Парето-анализ причин простоев
WITH reason_totals AS (
    SELECT
        r.reason_name,
        ROUND(SUM(fd.duration_min) / 60.0, 2) AS total_hours
    FROM fact_equipment_downtime fd
    JOIN dim_date d
        ON d.date_id = fd.date_id
    JOIN dim_downtime_reason r
        ON r.reason_id = fd.reason_id
    WHERE d.year = 2024
      AND d.month BETWEEN 1 AND 6
    GROUP BY r.reason_name
),
pareto AS (
    SELECT
        reason_name,
        total_hours,
        ROUND(100.0 * total_hours / NULLIF(SUM(total_hours) OVER (), 0), 2) AS pct_of_total,
        ROUND(
            100.0 * SUM(total_hours) OVER (
                ORDER BY total_hours DESC, reason_name
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) / NULLIF(SUM(total_hours) OVER (), 0),
            2
        ) AS cumulative_pct
    FROM reason_totals
)
SELECT
    reason_name,
    total_hours,
    pct_of_total,
    cumulative_pct,
    CASE
        WHEN cumulative_pct <= 80 THEN 'A'
        WHEN cumulative_pct <= 95 THEN 'B'
        ELSE 'C'
    END AS pareto_category
FROM pareto
ORDER BY total_hours DESC, reason_name;

-- Задание 10. Дедупликация и обработка повторных записей
WITH numbered AS (
    SELECT
        ft.*,
        ROW_NUMBER() OVER (
            PARTITION BY ft.sensor_id, ft.date_id, ft.time_id
            ORDER BY ft.telemetry_id DESC
        ) AS rn
    FROM fact_equipment_telemetry ft
),
dedup AS (
    SELECT *
    FROM numbered
    WHERE rn = 1
),
stats AS (
    SELECT
        (SELECT COUNT(*) FROM fact_equipment_telemetry) AS total_before,
        (SELECT COUNT(*) FROM dedup) AS total_after
)
SELECT
    total_before,
    total_after,
    total_before - total_after AS duplicates_removed,
    ROUND(
        100.0 * (total_before - total_after) / NULLIF(total_before, 0),
        2
    ) AS duplicate_pct
FROM stats;

-- Задание 11. Предиктивное обслуживание: аномалии в телеметрии
WITH base AS (
    SELECT
        ft.telemetry_id,
        ft.sensor_id,
        s.sensor_code,
        st.type_name AS sensor_type,
        d.full_date,
        t.full_time,
        ft.sensor_value,
        ft.is_alarm
    FROM fact_equipment_telemetry ft
    JOIN dim_sensor s
        ON s.sensor_id = ft.sensor_id
    JOIN dim_sensor_type st
        ON st.sensor_type_id = s.sensor_type_id
    JOIN dim_date d
        ON d.date_id = ft.date_id
    JOIN dim_time t
        ON t.time_id = ft.time_id
    WHERE ft.equipment_id = 1
      AND d.full_date BETWEEN DATE '2024-01-01' AND DATE '2024-01-07'
),
calc AS (
    SELECT
        telemetry_id,
        sensor_id,
        sensor_code,
        sensor_type,
        full_date,
        full_time,
        sensor_value,
        is_alarm,
        ROUND(AVG(sensor_value) OVER w8, 4) AS ma8,
        ROUND(STDDEV_SAMP(sensor_value) OVER w8, 4) AS stddev8,
        ROUND(
            sensor_value - LAG(sensor_value) OVER w_seq,
            4
        ) AS delta_prev,
        ROUND(PERCENT_RANK() OVER (
            PARTITION BY sensor_id
            ORDER BY sensor_value
        ), 4) AS pct_rank
    FROM base
    WINDOW
        w8 AS (
            PARTITION BY sensor_id
            ORDER BY full_date, full_time
            ROWS BETWEEN 7 PRECEDING AND CURRENT ROW
        ),
        w_seq AS (
            PARTITION BY sensor_id
            ORDER BY full_date, full_time
        )
),
risked AS (
    SELECT
        *,
        CASE
            WHEN pct_rank > 0.95 THEN 'ОПАСНОСТЬ'
            WHEN pct_rank > 0.85 THEN 'ВНИМАНИЕ'
            ELSE 'Норма'
        END AS risk_level
    FROM calc
)
SELECT
    sensor_code,
    sensor_type,
    full_date,
    full_time,
    sensor_value,
    ma8,
    stddev8,
    delta_prev,
    pct_rank,
    risk_level
FROM risked
WHERE risk_level <> 'Норма'
ORDER BY sensor_code, full_date, full_time;

-- Задание 12. Комплексный производственный дашборд
WITH daily AS (
    SELECT
        d.full_date,
        SUM(fp.tons_mined) AS tons
    FROM fact_production fp
    JOIN dim_date d
        ON d.date_id = fp.date_id
    WHERE fp.mine_id = 1
      AND d.year = 2024
      AND d.month = 1
    GROUP BY d.full_date
),
calc AS (
    SELECT
        full_date,
        tons,
        LAG(tons) OVER w_seq AS prev_day_tons,
        ROUND(AVG(tons) OVER w7, 2) AS ma7_tons,
        SUM(tons) OVER w_run AS running_tons,
        RANK() OVER (ORDER BY tons DESC) AS day_rank,
        NTILE(3) OVER (ORDER BY tons DESC) AS ntile3,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tons) OVER () AS median_tons
    FROM daily
    WINDOW
        w_seq AS (ORDER BY full_date),
        w7 AS (
            ORDER BY full_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ),
        w_run AS (
            ORDER BY full_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )
)
SELECT
    full_date,
    tons,
    prev_day_tons,
    ROUND(
        100.0 * (tons - prev_day_tons) / NULLIF(prev_day_tons, 0),
        2
    ) AS day_to_day_pct,
    ma7_tons,
    running_tons,
    day_rank,
    CASE ntile3
        WHEN 1 THEN 'Высокая'
        WHEN 2 THEN 'Средняя'
        ELSE 'Низкая'
    END AS production_category,
    median_tons,
    ROUND(
        100.0 * (tons - median_tons) / NULLIF(median_tons, 0),
        2
    ) AS deviation_from_median_pct,
    CASE
        WHEN prev_day_tons IS NULL THEN NULL
        WHEN ABS(100.0 * (tons - prev_day_tons) / NULLIF(prev_day_tons, 0)) < 5 THEN 'стабильно'
        WHEN tons > prev_day_tons THEN 'рост'
        ELSE 'снижение'
    END AS trend
FROM calc
ORDER BY full_date;
