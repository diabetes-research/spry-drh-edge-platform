CREATE TABLE IF NOT EXISTS drh_pipeline_steps (
    step INTEGER PRIMARY KEY,
    name TEXT,
    status TEXT CHECK (status IN ('pending','running','succeeded','failed')),
    started_at TEXT,
    completed_at TEXT,
    error TEXT
);

INSERT OR IGNORE INTO drh_pipeline_steps (step, name, status) VALUES
(1, 'Data Transformation', 'pending'),
(2, 'Data Validation', 'pending'),
(3, 'Data Anonymization', 'pending'),
(4, 'Master Data ETL', 'pending'),
(5, 'Metrics Transformation', 'pending');
