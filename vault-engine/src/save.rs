#[cfg(test)]
mod tests {
    use crate::adapters::fs::note_writer::{rename_temp_file, stable_content_hash};
    use crate::adapters::fs::path_resolver::VaultRoot;
    use crate::adapters::sqlite::{IndexingQueue, IndexingQueueReason};
    use crate::core::paths::PathError;
    use crate::use_cases::save_note::enqueue_saved_file;
    use crate::use_cases::save_note::{
        SafeSaveError, SaveBaseline, SaveConflict, SaveConflictChoice, SaveConflictChoiceError,
        SaveConflictKind, SaveIoOperation, SaveRequest, keep_conflicted_buffer_as_new_note,
        overwrite_after_conflict, reload_after_conflict, safe_save, safe_save_and_enqueue_own_save,
    };
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::{PermissionsExt, symlink};
    use std::path::{Path, PathBuf};
    use tempfile::TempDir;

    const BENCHMARK_VAULT: &str = "/Users/heeung/Documents/Codex Vault";

    struct SaveFixture {
        _temp: TempDir,
        root_path: PathBuf,
        root: VaultRoot,
    }

    #[test]
    fn copied_save_fixture_never_uses_real_benchmark_vault() {
        let fixture = copied_save_fixture();

        assert_not_benchmark_vault(&fixture.root_path);
        assert_ne!(fixture.root.canonical_root(), Path::new(BENCHMARK_VAULT));
    }

    #[test]
    fn normal_safe_save_writes_exact_bytes_and_updates_baseline() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let original_mode = unix_mode(&target);
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        let edited = b"\xEF\xBB\xBF# Home\r\nEdited with CRLF\r\n";

        let outcome =
            safe_save(&fixture.root, SaveRequest::new(&baseline, edited)).expect("safe save");

        assert_eq!(fs::read(&target).expect("read saved"), edited);
        assert_eq!(outcome.bytes_written, edited.len() as u64);
        assert_eq!(outcome.baseline.relative_path, "Home.md");
        assert_eq!(outcome.baseline.size_bytes, edited.len() as u64);
        assert_eq!(outcome.baseline.content_hash, stable_content_hash(edited));
        assert_eq!(unix_mode(&target), original_mode);
        assert_no_temp_files(&fixture.root_path);
    }

    #[test]
    fn safe_save_and_enqueue_own_save_returns_baseline_without_false_conflict() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let outcome = safe_save_and_enqueue_own_save(
            &fixture.root,
            &mut queue,
            SaveRequest::new(&baseline, b"# First app edit\n"),
            2,
        )
        .expect("own save");

        assert_eq!(
            fs::read_to_string(&target).expect("target"),
            "# First app edit\n"
        );
        assert_eq!(outcome.bytes_written, b"# First app edit\n".len() as u64);
        assert!(!outcome.dirty);
        assert_eq!(outcome.queued_item.reason, IndexingQueueReason::OwnSave);
        assert_eq!(outcome.queued_item.generation, 2);

        let second = safe_save(
            &fixture.root,
            SaveRequest::new(&outcome.baseline, b"# Second app edit\n"),
        )
        .expect("second save should not see own save as external conflict");

        assert_eq!(
            second.baseline.content_hash,
            stable_content_hash(b"# Second app edit\n")
        );
    }

    #[test]
    fn same_generation_watcher_change_preserves_own_save_queue_reason() {
        let fixture = copied_save_fixture();
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let outcome = safe_save_and_enqueue_own_save(
            &fixture.root,
            &mut queue,
            SaveRequest::new(&baseline, b"# App edit\n"),
            2,
        )
        .expect("own save");
        let watcher_item = enqueue_saved_file(
            &mut queue,
            &outcome.baseline,
            2,
            IndexingQueueReason::FileChanged,
        )
        .expect("watcher item");

        assert_eq!(watcher_item.reason, IndexingQueueReason::OwnSave);
        assert_eq!(
            queue
                .get_by_file_id("home.md")
                .expect("queue")
                .expect("item")
                .reason,
            IndexingQueueReason::OwnSave
        );
    }

    #[test]
    fn safe_save_rejects_external_edit_without_overwriting() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        fs::write(&target, "# External edit\n").expect("external edit");

        let error = safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"))
            .expect_err("conflict");

        assert_conflict_kind(error, SaveConflictKind::ContentChanged);
        assert_eq!(
            fs::read_to_string(&target).expect("read target"),
            "# External edit\n"
        );
    }

    #[test]
    fn safe_save_rejects_external_delete_without_recreating() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        fs::remove_file(&target).expect("external delete");

        let error = safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"))
            .expect_err("deleted conflict");

        assert_conflict_kind(error, SaveConflictKind::Deleted);
        assert!(!target.exists());
    }

    #[test]
    fn safe_save_rejects_external_replace_without_overwriting() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let replacement = fixture.root_path.join("Replacement.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        fs::write(&replacement, "# Replacement\n").expect("replacement");
        fs::rename(&replacement, &target).expect("external replace");

        let error = safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"))
            .expect_err("identity conflict");

        assert_conflict_kind(error, SaveConflictKind::FileIdentityChanged);
        assert_eq!(
            fs::read_to_string(&target).expect("read target"),
            "# Replacement\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn safe_save_rejects_symlink_swap_outside_vault() {
        let fixture = copied_save_fixture();
        let outside = tempfile::tempdir().expect("outside");
        fs::write(outside.path().join("secret.md"), "# Secret\n").expect("secret");
        let target = fixture.root_path.join("Home.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        fs::remove_file(&target).expect("remove original");
        symlink(outside.path().join("secret.md"), &target).expect("symlink");

        let error = safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"))
            .expect_err("symlink conflict");

        assert_conflict_kind(error, SaveConflictKind::SymlinkChanged);
        assert_eq!(
            fs::read_to_string(outside.path().join("secret.md")).expect("outside unchanged"),
            "# Secret\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn save_baseline_rejects_hardlinked_note_without_reading_outside_content() {
        let fixture = copied_save_fixture();
        let outside = tempfile::tempdir().expect("outside");
        fs::write(outside.path().join("shared.md"), "# Secret\n").expect("outside");
        let target = fixture.root_path.join("Shared.md");
        std::fs::hard_link(outside.path().join("shared.md"), &target).expect("hardlink");

        let error = SaveBaseline::capture(&fixture.root, "Shared.md").expect_err("hardlink");

        assert!(matches!(
            error,
            SafeSaveError::Path(PathError::UnsupportedHardlink(_))
        ));
        assert_eq!(
            fs::read_to_string(outside.path().join("shared.md")).expect("outside unchanged"),
            "# Secret\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn safe_save_rejects_read_only_target() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        let original = fs::read_to_string(&target).expect("original");
        let mut permissions = fs::metadata(&target).expect("metadata").permissions();
        permissions.set_mode(0o444);
        fs::set_permissions(&target, permissions).expect("read only");

        let error = safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"))
            .expect_err("read only");

        assert_eq!(
            error,
            SafeSaveError::ReadOnly {
                relative_path: "Home.md".to_string()
            }
        );
        assert_eq!(fs::read_to_string(&target).expect("target"), original);
    }

    #[cfg(unix)]
    #[test]
    fn safe_save_preserves_file_when_temp_write_cannot_start() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        let original = fs::read_to_string(&target).expect("original");
        let original_mode = fs::metadata(&fixture.root_path)
            .expect("root metadata")
            .permissions()
            .mode();
        let mut permissions = fs::metadata(&fixture.root_path)
            .expect("root metadata")
            .permissions();
        permissions.set_mode(0o555);
        fs::set_permissions(&fixture.root_path, permissions).expect("read-only directory");

        let result = safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"));

        let mut restore_permissions = fs::metadata(&fixture.root_path)
            .expect("root metadata")
            .permissions();
        restore_permissions.set_mode(original_mode);
        fs::set_permissions(&fixture.root_path, restore_permissions).expect("restore directory");

        match result.expect_err("temp create failure") {
            SafeSaveError::Io {
                operation: SaveIoOperation::CreateTemp,
                kind: std::io::ErrorKind::PermissionDenied,
                ..
            } => {}
            other => panic!("expected temp create permission error, got {other:?}"),
        }
        assert_eq!(fs::read_to_string(&target).expect("target"), original);
        assert_no_temp_files(&fixture.root_path);
    }

    #[test]
    fn atomic_replace_failure_cleans_temp_file() {
        let temp = tempfile::tempdir().expect("tempdir");
        let temp_file = temp.path().join(".Home.md.native-markdown-save.test.tmp");
        let target_directory = temp.path().join("Home.md");
        fs::write(&temp_file, "# App edit\n").expect("temp file");
        fs::create_dir(&target_directory).expect("target directory");

        let error = rename_temp_file(&temp_file, &target_directory, Path::new("Home.md"))
            .expect_err("rename failure");

        match error {
            SafeSaveError::Io {
                operation: SaveIoOperation::RenameTemp,
                ..
            } => {}
            other => panic!("expected rename temp error, got {other:?}"),
        }
        assert!(!temp_file.exists());
        assert!(target_directory.is_dir());
    }

    #[test]
    fn reload_after_conflict_updates_buffer_baseline_and_queues_changed_file() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        fs::write(&target, "# External edit\n").expect("external edit");
        let conflict = save_conflict(
            safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"))
                .expect_err("conflict"),
        );
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let outcome =
            reload_after_conflict(&fixture.root, &mut queue, &conflict, 2).expect("reload");

        assert_eq!(outcome.contents, b"# External edit\n");
        assert_eq!(outcome.baseline.relative_path, "Home.md");
        assert_eq!(
            outcome.baseline.content_hash,
            stable_content_hash(b"# External edit\n")
        );
        assert!(!outcome.dirty);
        assert_eq!(outcome.queued_item.reason, IndexingQueueReason::FileChanged);
        assert_eq!(outcome.queued_item.generation, 2);
    }

    #[test]
    fn keep_conflicted_buffer_as_new_note_preserves_original_and_queues_own_save() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let new_note = fixture.root_path.join("Conflict Copy.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        fs::write(&target, "# External edit\n").expect("external edit");
        let _conflict = save_conflict(
            safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"))
                .expect_err("conflict"),
        );
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let outcome = keep_conflicted_buffer_as_new_note(
            &fixture.root,
            &mut queue,
            "Conflict Copy.md",
            b"# App edit\n",
            2,
        )
        .expect("keep as new");

        assert_eq!(
            fs::read_to_string(&target).expect("target"),
            "# External edit\n"
        );
        assert_eq!(
            fs::read_to_string(new_note).expect("new note"),
            "# App edit\n"
        );
        assert_eq!(outcome.choice, SaveConflictChoice::KeepAsNewNote);
        assert_eq!(outcome.baseline.relative_path, "Conflict Copy.md");
        assert_eq!(outcome.bytes_written, b"# App edit\n".len() as u64);
        assert!(!outcome.dirty);
        assert_eq!(outcome.queued_item.reason, IndexingQueueReason::OwnSave);
        assert_eq!(outcome.queued_item.generation, 2);
    }

    #[test]
    fn keep_as_new_note_refuses_existing_target_without_overwriting() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let original = fs::read_to_string(&target).expect("original");
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let error = keep_conflicted_buffer_as_new_note(
            &fixture.root,
            &mut queue,
            "Home.md",
            b"# New buffer\n",
            2,
        )
        .expect_err("existing target");

        match error {
            SaveConflictChoiceError::Save(SafeSaveError::Io {
                operation: SaveIoOperation::CreateNewNote,
                kind: std::io::ErrorKind::AlreadyExists,
                ..
            }) => {}
            other => panic!("expected create new note already exists error, got {other:?}"),
        }
        assert_eq!(fs::read_to_string(&target).expect("target"), original);
        assert_eq!(queue.summary().expect("queue").pending, 0);
    }

    #[test]
    fn overwrite_after_conflict_replaces_regular_file_and_queues_own_save() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        fs::write(&target, "# External edit\n").expect("external edit");
        let conflict = save_conflict(
            safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"))
                .expect_err("conflict"),
        );
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let outcome =
            overwrite_after_conflict(&fixture.root, &mut queue, &conflict, b"# App edit\n", 2)
                .expect("overwrite");

        assert_eq!(fs::read_to_string(&target).expect("target"), "# App edit\n");
        assert_eq!(outcome.choice, SaveConflictChoice::Overwrite);
        assert_eq!(outcome.bytes_written, b"# App edit\n".len() as u64);
        assert!(!outcome.dirty);
        assert_eq!(outcome.queued_item.reason, IndexingQueueReason::OwnSave);
        assert_eq!(outcome.queued_item.generation, 2);
    }

    #[test]
    fn overwrite_after_deleted_conflict_is_not_safe() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        fs::remove_file(&target).expect("delete");
        let conflict = save_conflict(
            safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"))
                .expect_err("deleted conflict"),
        );
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let error =
            overwrite_after_conflict(&fixture.root, &mut queue, &conflict, b"# App edit\n", 2)
                .expect_err("unsafe overwrite");

        match error {
            SaveConflictChoiceError::Save(SafeSaveError::Conflict(conflict)) => {
                assert_eq!(conflict.kind, SaveConflictKind::Deleted);
            }
            other => panic!("expected deleted conflict, got {other:?}"),
        }
        assert!(!target.exists());
        assert_eq!(queue.summary().expect("queue").pending, 0);
    }

    fn copied_save_fixture() -> SaveFixture {
        let temp = tempfile::tempdir().expect("tempdir");
        let root_path = temp.path().join("copied-save-vault");
        copy_dir(&compatibility_fixture_root(), &root_path);
        assert_not_benchmark_vault(&root_path);
        let root = VaultRoot::open(&root_path).expect("root");

        SaveFixture {
            _temp: temp,
            root_path,
            root,
        }
    }

    fn compatibility_fixture_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("compatibility-vault")
    }

    fn copy_dir(source: &Path, destination: &Path) {
        fs::create_dir_all(destination).expect("destination");
        for entry in fs::read_dir(source).expect("read source") {
            let entry = entry.expect("entry");
            let source_path = entry.path();
            let destination_path = destination.join(entry.file_name());
            let file_type = entry.file_type().expect("file type");
            if file_type.is_dir() {
                copy_dir(&source_path, &destination_path);
            } else if file_type.is_file() {
                fs::copy(&source_path, &destination_path).expect("copy file");
            }
        }
    }

    fn assert_not_benchmark_vault(path: &Path) {
        let benchmark = Path::new(BENCHMARK_VAULT);
        assert_ne!(path, benchmark);
        assert!(!path.starts_with(benchmark));
    }

    fn assert_conflict_kind(error: SafeSaveError, expected: SaveConflictKind) {
        match error {
            SafeSaveError::Conflict(conflict) => assert_eq!(conflict.kind, expected),
            other => panic!("expected conflict {expected:?}, got {other:?}"),
        }
    }

    fn save_conflict(error: SafeSaveError) -> SaveConflict {
        match error {
            SafeSaveError::Conflict(conflict) => *conflict,
            other => panic!("expected save conflict, got {other:?}"),
        }
    }

    fn assert_no_temp_files(root_path: &Path) {
        let leaked = fs::read_dir(root_path)
            .expect("read root")
            .filter_map(Result::ok)
            .any(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .contains(".native-markdown-save.")
            });
        assert!(!leaked);
    }

    #[cfg(unix)]
    fn unix_mode(path: &Path) -> Option<u32> {
        Some(fs::metadata(path).expect("metadata").permissions().mode() & 0o777)
    }

    #[cfg(not(unix))]
    fn unix_mode(_path: &Path) -> Option<u32> {
        None
    }
}
