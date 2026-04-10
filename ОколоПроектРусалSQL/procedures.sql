CREATE OR REPLACE FUNCTION industrial_scale.get_calibration(p_scale_id INTEGER)
RETURNS TABLE(k NUMERIC, b NUMERIC, calibrated_at TIMESTAMPTZ)
LANGUAGE sql
STABLE
AS $$
SELECT k_coefficient, b_offset, calibrated_at
FROM industrial_scale.scale_calibration
WHERE scale_id = p_scale_id;
$$;

CREATE OR REPLACE FUNCTION industrial_scale.save_calibration(
    p_scale_id INTEGER,
    p_k NUMERIC,
    p_b NUMERIC,
    p_calibrated_by VARCHAR DEFAULT NULL
)
    RETURNS VOID
    LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO industrial_scale.scale_calibration (scale_id, k_coefficient, b_offset, calibrated_by)
    VALUES (p_scale_id, p_k, p_b, p_calibrated_by)
    ON CONFLICT (scale_id) DO UPDATE
        SET k_coefficient = EXCLUDED.k_coefficient,
            b_offset = EXCLUDED.b_offset,
            calibrated_at = NOW(),
            calibrated_by = EXCLUDED.calibrated_by;
END;
$$;

/*
-- Заглушка: внешняя процедура определения места (не наша реализация)
-- Мы только объявляем её сигнатуру. Реальное тело будет в другом месте.
CREATE OR REPLACE FUNCTION external_warehouse.suggest_storage_location(
    p_barcode VARCHAR,
    p_corrected_weight NUMERIC
)
    RETURNS VARCHAR
    LANGUAGE plpgsql
AS $$
BEGIN
    -- Здесь вызывается реальный сервис склада.
    -- Пока заглушка возвращает NULL или 'A-01-23'
    RETURN NULL;
END;
$$;
*/

-- Наша основная процедура сохранения взвешивания
CREATE OR REPLACE FUNCTION industrial_scale.save_weighing(
    p_scale_id INTEGER,
    p_raw_value NUMERIC,
    p_barcode VARCHAR DEFAULT NULL,
    p_weighing_time TIMESTAMPTZ DEFAULT NULL
)
    RETURNS BIGINT   -- ID новой записи
    LANGUAGE plpgsql
AS $$
DECLARE
    v_k NUMERIC;
    v_b NUMERIC;
    v_corrected_weight NUMERIC;
    v_storage_location VARCHAR;
    v_now TIMESTAMPTZ := COALESCE(p_weighing_time, NOW());
    v_record_id BIGINT;
BEGIN
    -- 1. Получаем калибровку весов
    SELECT k_coefficient, b_offset INTO v_k, v_b
    FROM industrial_scale.scale_calibration
    WHERE scale_id = p_scale_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Калибровка для весов % не найдена', p_scale_id;
    END IF;

    -- 2. Вычисляем скорректированный вес (линейная коррекция)
    v_corrected_weight := v_k * p_raw_value + v_b;

    -- 3. Определяем место на складе (вызов внешней процедуры)
    v_storage_location := external_warehouse.suggest_storage_location(p_barcode, v_corrected_weight);

    -- 4. Сохраняем запись
    INSERT INTO industrial_scale.weighing_record (
        scale_id, raw_value, corrected_weight, barcode,
        weighing_time, storage_location_id, is_synced
    ) VALUES (
                 p_scale_id, p_raw_value, v_corrected_weight, p_barcode,
                 v_now, v_storage_location, TRUE   -- сразу синхронизировано из ОЗУ
             )
    RETURNING id INTO v_record_id;

    RETURN v_record_id;
END;
$$;

-- Терминал может передать массив взвешиваний разом
CREATE OR REPLACE FUNCTION industrial_scale.bulk_save_weighings(
    weighings_json JSONB   -- формат: [{"scale_id":1,"raw":100.5,"barcode":"123"}, ...]
)
    RETURNS TABLE(inserted_id BIGINT, status TEXT)
    LANGUAGE plpgsql
AS $$
DECLARE
    w RECORD;
    v_id BIGINT;
BEGIN
    FOR w IN SELECT * FROM jsonb_to_recordset(weighings_json) AS x(scale_id INTEGER, raw_value NUMERIC, barcode VARCHAR)
        LOOP
            BEGIN
                v_id := industrial_scale.save_weighing(w.scale_id, w.raw_value, w.barcode);
                RETURN QUERY SELECT v_id, 'OK';
            EXCEPTION WHEN OTHERS THEN
                RETURN QUERY SELECT NULL::BIGINT, SQLERRM;
            END;
        END LOOP;
END;
$$;