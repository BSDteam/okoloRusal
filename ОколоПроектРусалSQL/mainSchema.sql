-- Схема для логирования и настроек
CREATE SCHEMA IF NOT EXISTS industrial_scale;

-- Таблица калибровок весов (3NF: отдельная сущность "весы")
CREATE TABLE industrial_scale.scale_calibration (
                                                    scale_id        INTEGER PRIMARY KEY,      -- ID весов (уникальный)
                                                    k_coefficient   NUMERIC(10,6) NOT NULL DEFAULT 1.0,  -- k (коэффициент усиления)
                                                    b_offset        NUMERIC(10,6) NOT NULL DEFAULT 0.0,  -- b (смещение)
                                                    calibrated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                                                    calibrated_by   VARCHAR(100)              -- кто калибровал (опционально)
);

-- Таблица взвешиваний (основные факты)
CREATE TABLE industrial_scale.weighing_record (
                                                  id              BIGSERIAL PRIMARY KEY,
                                                  scale_id        INTEGER NOT NULL,
                                                  raw_value       NUMERIC(12,4) NOT NULL,   -- сырое значение с датчика
                                                  corrected_weight NUMERIC(12,4),           -- вес после применения калибровки (kx+b)
                                                  barcode         VARCHAR(100),             -- штрихкод груза
                                                  weighing_time   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                                                  storage_location_id VARCHAR(50),          -- место на складе (будет заполнено внешней процедурой)
                                                  is_synced       BOOLEAN DEFAULT FALSE,    -- для контроля выгрузки из ОЗУ
                                                  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Индексы для производительности
CREATE INDEX idx_weighing_scale_time ON industrial_scale.weighing_record (scale_id, weighing_time);
CREATE INDEX idx_weighing_barcode ON industrial_scale.weighing_record (barcode);
CREATE INDEX idx_weighing_synced ON industrial_scale.weighing_record (is_synced) WHERE is_synced = FALSE;