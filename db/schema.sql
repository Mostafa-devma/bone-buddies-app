-- =============================================================================
-- Orthopedic Clinic Management System — Local SQLite Schema
-- Phase 1: Complete database structure (offline, single-machine, expandable)
-- =============================================================================
-- Engine notes:
--   * Targets SQLite 3 (bundled with the desktop runtime / better-sqlite3).
--   * All timestamps are stored as ISO-8601 TEXT in UTC (e.g. 2026-07-13T09:00:00Z).
--   * Money is stored in INTEGER minor units (e.g. piasters/cents) to avoid float
--     rounding errors in billing. Currency code is stored alongside.
--   * Soft-delete via `deleted_at` on domain tables to preserve medical/legal history.
--   * Every mutable table carries created_at / updated_at for auditing & sync-readiness.
-- =============================================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;      -- concurrent reads while writing (desktop friendly)
PRAGMA synchronous = NORMAL;

-- =============================================================================
-- 0. SCHEMA VERSIONING (migrations)
-- =============================================================================
CREATE TABLE IF NOT EXISTS schema_migrations (
    version      INTEGER PRIMARY KEY,
    name         TEXT    NOT NULL,
    applied_at   TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- =============================================================================
-- 1. APPLICATION SETTINGS (key/value clinic configuration)
-- =============================================================================
CREATE TABLE IF NOT EXISTS app_settings (
    key          TEXT PRIMARY KEY,
    value        TEXT,
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- Clinic identity (single row, id = 1) used on invoices & printed receipts.
CREATE TABLE IF NOT EXISTS clinic_profile (
    id            INTEGER PRIMARY KEY CHECK (id = 1),
    name          TEXT NOT NULL,
    doctor_name   TEXT,
    specialty     TEXT DEFAULT 'Orthopedic Surgery',
    phone         TEXT,
    email         TEXT,
    address       TEXT,
    logo_path     TEXT,             -- local file path to logo asset
    tax_number    TEXT,
    currency      TEXT NOT NULL DEFAULT 'EGP',
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- =============================================================================
-- 2. STAFF, ROLES & AUTH (local accounts, offline)
-- =============================================================================
CREATE TABLE IF NOT EXISTS roles (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    code         TEXT NOT NULL UNIQUE,          -- 'admin','doctor','assistant','reception'
    name         TEXT NOT NULL,
    description  TEXT
);

CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT NOT NULL UNIQUE,
    full_name     TEXT NOT NULL,
    password_hash TEXT NOT NULL,                -- bcrypt/argon2 hash, never plaintext
    role_id       INTEGER NOT NULL REFERENCES roles(id),
    phone         TEXT,
    is_active     INTEGER NOT NULL DEFAULT 1,   -- boolean 0/1
    last_login_at TEXT,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    deleted_at    TEXT
);
CREATE INDEX IF NOT EXISTS idx_users_role ON users(role_id);

-- =============================================================================
-- 3. PATIENTS (core master record)
-- =============================================================================
CREATE TABLE IF NOT EXISTS patients (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    code            TEXT UNIQUE,                 -- human-friendly MRN, e.g. ORT-2026-00042
    first_name      TEXT NOT NULL,
    last_name       TEXT NOT NULL,
    gender          TEXT CHECK (gender IN ('male','female','other')),
    date_of_birth   TEXT,                        -- ISO date
    national_id     TEXT,
    phone           TEXT,
    phone_alt       TEXT,
    email           TEXT,
    address         TEXT,
    city            TEXT,
    blood_group     TEXT,
    occupation      TEXT,
    emergency_name  TEXT,
    emergency_phone TEXT,
    -- Orthopedic-relevant clinical context
    allergies       TEXT,
    chronic_conditions TEXT,
    current_medications TEXT,
    notes           TEXT,
    created_by      INTEGER REFERENCES users(id),
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    deleted_at      TEXT
);
CREATE INDEX IF NOT EXISTS idx_patients_name  ON patients(last_name, first_name);
CREATE INDEX IF NOT EXISTS idx_patients_phone ON patients(phone);
CREATE INDEX IF NOT EXISTS idx_patients_code  ON patients(code);

-- =============================================================================
-- 4. APPOINTMENTS / SCHEDULING
-- =============================================================================
CREATE TABLE IF NOT EXISTS appointments (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id     INTEGER NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    doctor_id      INTEGER REFERENCES users(id),
    scheduled_at   TEXT NOT NULL,                -- start datetime
    duration_min   INTEGER NOT NULL DEFAULT 15,
    status         TEXT NOT NULL DEFAULT 'scheduled'
                   CHECK (status IN ('scheduled','confirmed','arrived','in_progress','completed','cancelled','no_show')),
    reason         TEXT,                          -- chief complaint / purpose
    notes          TEXT,
    created_by     INTEGER REFERENCES users(id),
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    deleted_at     TEXT
);
CREATE INDEX IF NOT EXISTS idx_appts_patient ON appointments(patient_id);
CREATE INDEX IF NOT EXISTS idx_appts_time    ON appointments(scheduled_at);
CREATE INDEX IF NOT EXISTS idx_appts_status  ON appointments(status);

-- =============================================================================
-- 5. CLINICAL ENCOUNTERS (visits / consultations)
-- =============================================================================
CREATE TABLE IF NOT EXISTS encounters (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id      INTEGER NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    appointment_id  INTEGER REFERENCES appointments(id) ON DELETE SET NULL,
    doctor_id       INTEGER REFERENCES users(id),
    encounter_date  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    visit_type      TEXT DEFAULT 'consultation'
                    CHECK (visit_type IN ('consultation','follow_up','emergency','post_op','procedure')),
    -- SOAP-style clinical notes
    chief_complaint TEXT,
    history         TEXT,          -- history of present illness
    examination     TEXT,          -- physical / orthopedic exam findings
    assessment      TEXT,          -- clinical impression
    plan            TEXT,          -- management plan
    -- Vitals snapshot
    height_cm       REAL,
    weight_kg       REAL,
    bp_systolic     INTEGER,
    bp_diastolic    INTEGER,
    pulse_bpm       INTEGER,
    temperature_c   REAL,
    notes           TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    deleted_at      TEXT
);
CREATE INDEX IF NOT EXISTS idx_enc_patient ON encounters(patient_id);
CREATE INDEX IF NOT EXISTS idx_enc_date    ON encounters(encounter_date);

-- =============================================================================
-- 6. DIAGNOSES (ICD-ready, orthopedic-friendly)
-- =============================================================================
CREATE TABLE IF NOT EXISTS diagnosis_catalog (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    code         TEXT UNIQUE,          -- ICD-10 e.g. S52.5, M17.1
    name         TEXT NOT NULL,
    category     TEXT,                 -- fracture / arthritis / soft-tissue / congenital ...
    is_active    INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS encounter_diagnoses (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    encounter_id   INTEGER NOT NULL REFERENCES encounters(id) ON DELETE CASCADE,
    diagnosis_id   INTEGER REFERENCES diagnosis_catalog(id),
    -- free text kept even when catalog id is null (custom diagnosis)
    description    TEXT,
    -- orthopedic anatomy specifics
    body_site      TEXT,               -- e.g. 'left femur', 'right knee'
    laterality     TEXT CHECK (laterality IN ('left','right','bilateral','na')),
    is_primary     INTEGER NOT NULL DEFAULT 0,
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_encdx_encounter ON encounter_diagnoses(encounter_id);

-- =============================================================================
-- 7. PRESCRIPTIONS & MEDICATIONS
-- =============================================================================
CREATE TABLE IF NOT EXISTS medications (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    form         TEXT,                 -- tablet / capsule / injection / ointment
    strength     TEXT,                 -- e.g. '500 mg'
    is_active    INTEGER NOT NULL DEFAULT 1,
    UNIQUE(name, strength, form)
);

CREATE TABLE IF NOT EXISTS prescriptions (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    encounter_id   INTEGER REFERENCES encounters(id) ON DELETE SET NULL,
    patient_id     INTEGER NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    doctor_id      INTEGER REFERENCES users(id),
    issued_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    notes          TEXT,
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    deleted_at     TEXT
);
CREATE INDEX IF NOT EXISTS idx_rx_patient ON prescriptions(patient_id);

CREATE TABLE IF NOT EXISTS prescription_items (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    prescription_id  INTEGER NOT NULL REFERENCES prescriptions(id) ON DELETE CASCADE,
    medication_id    INTEGER REFERENCES medications(id),
    drug_name        TEXT NOT NULL,          -- captured even for free-text drugs
    dosage           TEXT,                   -- '1 tab'
    frequency        TEXT,                   -- 'twice daily'
    duration         TEXT,                   -- '7 days'
    route            TEXT,                   -- oral / IM / topical
    instructions     TEXT
);
CREATE INDEX IF NOT EXISTS idx_rxitem_rx ON prescription_items(prescription_id);

-- =============================================================================
-- 8. PROCEDURES & SURGERIES (orthopedic core)
-- =============================================================================
CREATE TABLE IF NOT EXISTS procedure_catalog (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    code         TEXT UNIQUE,
    name         TEXT NOT NULL,             -- ORIF, arthroscopy, joint replacement...
    default_price INTEGER NOT NULL DEFAULT 0, -- minor units
    is_active    INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS procedures (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id      INTEGER NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    encounter_id    INTEGER REFERENCES encounters(id) ON DELETE SET NULL,
    catalog_id      INTEGER REFERENCES procedure_catalog(id),
    name            TEXT NOT NULL,
    surgeon_id      INTEGER REFERENCES users(id),
    performed_at    TEXT,
    body_site       TEXT,
    laterality      TEXT CHECK (laterality IN ('left','right','bilateral','na')),
    -- implant / hardware tracking (orthopedic specific)
    implant_used    TEXT,
    implant_serial  TEXT,
    anesthesia_type TEXT,
    outcome         TEXT,
    complications   TEXT,
    notes           TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    deleted_at      TEXT
);
CREATE INDEX IF NOT EXISTS idx_proc_patient ON procedures(patient_id);

-- =============================================================================
-- 9. IMAGING & DOCUMENTS / ATTACHMENTS (X-rays, MRI, reports)
-- =============================================================================
CREATE TABLE IF NOT EXISTS attachments (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id     INTEGER NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    encounter_id   INTEGER REFERENCES encounters(id) ON DELETE SET NULL,
    kind           TEXT NOT NULL DEFAULT 'other'
                   CHECK (kind IN ('xray','mri','ct','ultrasound','lab','report','photo','other')),
    title          TEXT,
    file_path      TEXT NOT NULL,          -- local path under app data dir
    mime_type      TEXT,
    file_size      INTEGER,
    body_site      TEXT,
    taken_at       TEXT,
    notes          TEXT,
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    deleted_at     TEXT
);
CREATE INDEX IF NOT EXISTS idx_attach_patient ON attachments(patient_id);
CREATE INDEX IF NOT EXISTS idx_attach_kind    ON attachments(kind);

-- =============================================================================
-- 10. BILLING — SERVICES, INVOICES, PAYMENTS
-- =============================================================================
CREATE TABLE IF NOT EXISTS services (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    code         TEXT UNIQUE,
    name         TEXT NOT NULL,            -- consultation, dressing, injection...
    unit_price   INTEGER NOT NULL DEFAULT 0,  -- minor units
    tax_percent  REAL NOT NULL DEFAULT 0,
    is_active    INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS invoices (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    invoice_no     TEXT NOT NULL UNIQUE,      -- e.g. INV-2026-000123
    patient_id     INTEGER NOT NULL REFERENCES patients(id),
    encounter_id   INTEGER REFERENCES encounters(id) ON DELETE SET NULL,
    issued_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    currency       TEXT NOT NULL DEFAULT 'EGP',
    subtotal       INTEGER NOT NULL DEFAULT 0,   -- minor units
    discount       INTEGER NOT NULL DEFAULT 0,
    tax_total      INTEGER NOT NULL DEFAULT 0,
    total          INTEGER NOT NULL DEFAULT 0,
    amount_paid    INTEGER NOT NULL DEFAULT 0,
    status         TEXT NOT NULL DEFAULT 'unpaid'
                   CHECK (status IN ('draft','unpaid','partial','paid','void')),
    notes          TEXT,
    created_by     INTEGER REFERENCES users(id),
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    deleted_at     TEXT
);
CREATE INDEX IF NOT EXISTS idx_inv_patient ON invoices(patient_id);
CREATE INDEX IF NOT EXISTS idx_inv_status  ON invoices(status);
CREATE INDEX IF NOT EXISTS idx_inv_date    ON invoices(issued_at);

CREATE TABLE IF NOT EXISTS invoice_items (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    invoice_id     INTEGER NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    service_id     INTEGER REFERENCES services(id),
    procedure_id   INTEGER REFERENCES procedures(id),
    description    TEXT NOT NULL,
    quantity       REAL NOT NULL DEFAULT 1,
    unit_price     INTEGER NOT NULL DEFAULT 0,  -- minor units
    discount       INTEGER NOT NULL DEFAULT 0,
    tax_percent    REAL NOT NULL DEFAULT 0,
    line_total     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_invitem_inv ON invoice_items(invoice_id);

CREATE TABLE IF NOT EXISTS payments (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    invoice_id     INTEGER NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    amount         INTEGER NOT NULL,             -- minor units
    method         TEXT NOT NULL DEFAULT 'cash'
                   CHECK (method IN ('cash','card','transfer','wallet','other')),
    reference      TEXT,
    paid_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    received_by    INTEGER REFERENCES users(id),
    notes          TEXT,
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_pay_invoice ON payments(invoice_id);

-- =============================================================================
-- 11. THERMAL PRINTING (Xprinter / ESC/POS configuration & log)
-- =============================================================================
CREATE TABLE IF NOT EXISTS printers (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    name           TEXT NOT NULL,
    interface_type TEXT NOT NULL DEFAULT 'usb'
                   CHECK (interface_type IN ('usb','network','serial','bluetooth')),
    -- connection details depend on interface_type
    address        TEXT,                    -- IP:port, COM3, USB path, or MAC
    paper_width    INTEGER NOT NULL DEFAULT 80 CHECK (paper_width IN (58,80)), -- mm
    chars_per_line INTEGER NOT NULL DEFAULT 48,
    codepage       TEXT DEFAULT 'CP437',
    is_default     INTEGER NOT NULL DEFAULT 0,
    is_active      INTEGER NOT NULL DEFAULT 1,
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS print_templates (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    code         TEXT NOT NULL UNIQUE,     -- 'invoice_80','invoice_58','prescription','receipt'
    name         TEXT NOT NULL,
    paper_width  INTEGER NOT NULL DEFAULT 80 CHECK (paper_width IN (58,80)),
    content      TEXT,                     -- template body (tokens like {{patient_name}})
    is_active    INTEGER NOT NULL DEFAULT 1,
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS print_jobs (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    printer_id     INTEGER REFERENCES printers(id),
    template_code  TEXT,
    document_type  TEXT,                    -- 'invoice','prescription','receipt'
    document_id    INTEGER,                 -- FK-by-convention to source record
    status         TEXT NOT NULL DEFAULT 'queued'
                   CHECK (status IN ('queued','printing','done','failed')),
    error_message  TEXT,
    created_by     INTEGER REFERENCES users(id),
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    completed_at   TEXT
);
CREATE INDEX IF NOT EXISTS idx_printjob_status ON print_jobs(status);

-- =============================================================================
-- 12. AUDIT LOG (security & accountability, offline)
-- =============================================================================
CREATE TABLE IF NOT EXISTS audit_log (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id      INTEGER REFERENCES users(id),
    action       TEXT NOT NULL,            -- 'create','update','delete','login','print'
    entity       TEXT NOT NULL,            -- table / domain name
    entity_id    INTEGER,
    details      TEXT,                     -- JSON diff / context
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_log(entity, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_user   ON audit_log(user_id);

-- =============================================================================
-- 13. SEED (baseline roles + record migration version)
-- =============================================================================
INSERT OR IGNORE INTO roles (code, name, description) VALUES
    ('admin',     'Administrator', 'Full system access'),
    ('doctor',    'Doctor',        'Clinical + prescribing access'),
    ('assistant', 'Assistant',     'Clinical support, limited billing'),
    ('reception', 'Reception',     'Scheduling & billing');

INSERT OR IGNORE INTO schema_migrations (version, name)
    VALUES (1, 'initial_schema');
