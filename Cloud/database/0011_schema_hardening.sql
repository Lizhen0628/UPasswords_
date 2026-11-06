-- Consolidate all synchronized ciphertext rows and harden tenant-scoped references.
-- Apply after 0010. The profile table is merged and then removed in this migration.

CREATE TABLE IF NOT EXISTS schema_migrations (
  version     INT UNSIGNED NOT NULL,
  filename    VARCHAR(128) NOT NULL,
  applied_ms  BIGINT NOT NULL,
  PRIMARY KEY (version)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Profiles use the same row contract as cards and labels. Fail the migration if an
-- unexpected duplicate identity exists instead of silently discarding one payload.
DROP VIEW IF EXISTS vault_sync_items;
CREATE TABLE IF NOT EXISTS vault_user_profiles LIKE vault_items;

INSERT INTO vault_items(
  vault_id,item_uuid,kind,revision,body,body_sha256,body_bytes,modified_ms,
  created_ms,updated_ms,origin_session_id,origin_device_name,origin_platform
)
SELECT
  vault_id,item_uuid,kind,revision,body,body_sha256,body_bytes,modified_ms,
  created_ms,updated_ms,origin_session_id,origin_device_name,origin_platform
FROM vault_user_profiles;

DROP TABLE vault_user_profiles;

ALTER TABLE vault_items
  ADD CONSTRAINT chk_vault_items_kind CHECK (kind IN (1, 2, 3));

ALTER TABLE users
  ADD CONSTRAINT chk_users_state CHECK (state IN ('active','deregistered')),
  ADD CONSTRAINT chk_users_plan CHECK (plan IN ('normal','subscription','permanent'));

ALTER TABLE email_codes
  ADD CONSTRAINT chk_email_codes_purpose CHECK (purpose IN ('login','sensitive')),
  ADD CONSTRAINT chk_email_codes_attempts CHECK (attempts >= 0);

ALTER TABLE item_changes
  ADD CONSTRAINT chk_item_changes_op CHECK (op IN (1, 2, 3, 4));

ALTER TABLE item_conflicts
  ADD CONSTRAINT chk_item_conflicts_status CHECK (status IN ('open','resolved'));

ALTER TABLE item_conflict_candidates
  ADD CONSTRAINT chk_item_conflict_candidate_disposition CHECK (disposition IN ('pending','retained'));

ALTER TABLE websites
  ADD CONSTRAINT chk_websites_status CHECK (status IN (0, 1));

CREATE OR REPLACE VIEW vault_sync_items AS
SELECT vault_id,item_uuid,kind,revision,body,body_sha256,body_bytes,modified_ms,
       created_ms,updated_ms,origin_session_id,origin_device_name,origin_platform
FROM vault_items;

-- The pointer is always materialized, including the legacy version sentinel.
UPDATE attachments
SET content_version='00000000-0000-0000-0000-000000000000'
WHERE content_version IS NULL;

ALTER TABLE attachments
  MODIFY COLUMN content_version CHAR(36) NOT NULL,
  ADD KEY IF NOT EXISTS idx_attachments_current_version(vault_id,attach_uuid,content_version),
  ADD CONSTRAINT fk_attachments_current_version
    FOREIGN KEY (vault_id,attach_uuid,content_version)
    REFERENCES attachment_versions(vault_id,attach_uuid,content_version)
    ON DELETE RESTRICT;

ALTER TABLE item_conflicts
  ADD UNIQUE KEY IF NOT EXISTS uq_item_conflicts_vault_id(vault_id,conflict_id),
  ADD KEY IF NOT EXISTS idx_conflicts_history(vault_id,status,resolved_ms,conflict_id);

ALTER TABLE rekeys
  ADD UNIQUE KEY IF NOT EXISTS uq_rekeys_vault_id(vault_id,rekey_id),
  ADD KEY IF NOT EXISTS idx_rekeys_expiry(expires_ms);

ALTER TABLE attachment_version_conflicts
  ADD CONSTRAINT fk_attachment_conflict_vault
    FOREIGN KEY (vault_id,conflict_id)
    REFERENCES item_conflicts(vault_id,conflict_id)
    ON DELETE CASCADE;

ALTER TABLE rekey_attachment_staging
  ADD CONSTRAINT fk_rekey_attachment_staging_vault
    FOREIGN KEY (vault_id,rekey_id)
    REFERENCES rekeys(vault_id,rekey_id)
    ON DELETE CASCADE;

ALTER TABLE rekey_staging
  ADD COLUMN IF NOT EXISTS vault_id VARCHAR(32) NULL AFTER rekey_id,
  ADD KEY IF NOT EXISTS idx_rekey_staging_vault(vault_id,rekey_id);

UPDATE rekey_staging s
JOIN rekeys r ON r.rekey_id=s.rekey_id
SET s.vault_id=r.vault_id
WHERE s.vault_id IS NULL;

ALTER TABLE rekey_staging
  MODIFY COLUMN vault_id VARCHAR(32) NOT NULL,
  ADD CONSTRAINT fk_rekey_staging_vault
    FOREIGN KEY (vault_id,rekey_id)
    REFERENCES rekeys(vault_id,rekey_id)
    ON DELETE CASCADE;

ALTER TABLE rekey_conflict_manifests
  ADD CONSTRAINT fk_rekey_conflict_manifest_vault
    FOREIGN KEY (vault_id,rekey_id)
    REFERENCES rekeys(vault_id,rekey_id)
    ON DELETE CASCADE;

ALTER TABLE rekey_conflict_staging
  ADD KEY IF NOT EXISTS idx_rekey_conflict_staging_conflict(vault_id,conflict_id,old_candidate_id),
  ADD CONSTRAINT fk_rekey_conflict_staging_vault
    FOREIGN KEY (vault_id,rekey_id)
    REFERENCES rekeys(vault_id,rekey_id)
    ON DELETE CASCADE,
  ADD CONSTRAINT fk_rekey_conflict_staging_conflict
    FOREIGN KEY (vault_id,conflict_id)
    REFERENCES item_conflicts(vault_id,conflict_id)
    ON DELETE CASCADE;

ALTER TABLE users
  ADD KEY IF NOT EXISTS idx_users_deregistered(state,deregistered_at_ms,id);

ALTER TABLE email_codes
  ADD COLUMN IF NOT EXISTS ip_hmc CHAR(64) NOT NULL DEFAULT '' AFTER ip,
  ADD KEY IF NOT EXISTS idx_email_codes_expiry(expires_ms);

-- Existing codes are short-lived and their raw IP is intentionally discarded.
UPDATE email_codes SET ip_hmc='';
ALTER TABLE email_codes DROP COLUMN IF EXISTS ip;

ALTER TABLE sessions
  ADD KEY IF NOT EXISTS idx_sessions_list(user_id,revoked_ms,last_seen_ms),
  ADD KEY IF NOT EXISTS idx_sessions_expiry(expires_ms),
  ADD KEY IF NOT EXISTS idx_sessions_revoked(revoked_ms);

ALTER TABLE item_changes
  ADD KEY IF NOT EXISTS idx_changes_retention(created_ms,vault_id,seq),
  ADD KEY IF NOT EXISTS idx_changes_conflict(vault_id,conflict_id,winner_candidate_id);

ALTER TABLE item_conflict_candidates
  ADD KEY IF NOT EXISTS idx_conflict_candidates_history(
    conflict_id,disposition,expires_ms,committed_ms,candidate_id
  );

ALTER TABLE attachment_versions
  ADD KEY IF NOT EXISTS idx_attachment_versions_purge(vault_id,purge_started_ms,unreferenced_ms);

ALTER TABLE audit_log
  ADD COLUMN IF NOT EXISTS email_hmc VARCHAR(128) NULL AFTER action,
  ADD COLUMN IF NOT EXISTS ip_hmc CHAR(64) NULL AFTER email_hmc,
  ADD COLUMN IF NOT EXISTS purpose VARCHAR(16) NULL AFTER ip_hmc,
  ADD KEY IF NOT EXISTS idx_audit_retention(ts_ms),
  ADD KEY IF NOT EXISTS idx_audit_code_email(action,email_hmc,ts_ms),
  ADD KEY IF NOT EXISTS idx_audit_code_ip(action,ip_hmc,ts_ms);

UPDATE audit_log
SET email_hmc=SUBSTRING_INDEX(SUBSTRING_INDEX(detail,' ',1),'=',-1),
    ip_hmc=SUBSTRING_INDEX(SUBSTRING_INDEX(detail,' ',2),'=',-1),
    purpose=SUBSTRING_INDEX(SUBSTRING_INDEX(detail,' ',3),'=',-1)
WHERE action='code_send' AND email_hmc IS NULL AND detail LIKE 'emailHmc=% ipHmc=% purpose=%';

INSERT INTO schema_migrations(version,filename,applied_ms)
VALUES(11,'0011_schema_hardening.sql',UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3))*1000)
ON DUPLICATE KEY UPDATE version=VALUES(version);
