use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::sync_channel;
use std::thread;

use super::indexing_pipeline::{
    IndexingPipelineError, IndexingPipelineOptions, IndexingPipelineResult, SearchDocumentSource,
};
use crate::adapters::tantivy::{TantivyIndexingStageMetrics, TantivySearchIndex};
use crate::core::search::SearchDocument;
use crate::use_cases::read_parse_documents::{
    PipelineCorpusStats, TimedSearchDocument, read_parse_source_at,
};

pub struct TantivyPipelineRun {
    pub stats: PipelineCorpusStats,
    pub peak_in_flight_items: usize,
    pub stages: TantivyIndexingStageMetrics,
}

pub fn run_tantivy_rebuild_pipeline(
    index: &mut TantivySearchIndex,
    sources: &[SearchDocumentSource],
    options: &IndexingPipelineOptions,
) -> IndexingPipelineResult<TantivyPipelineRun> {
    let options = options.normalized();
    let (sender, receiver) =
        sync_channel::<IndexingPipelineResult<TimedSearchDocument>>(options.channel_capacity);
    let next_source = AtomicUsize::new(0);
    let in_flight = Arc::new(AtomicUsize::new(0));
    let peak_in_flight = Arc::new(AtomicUsize::new(0));
    let mut stats = PipelineCorpusStats::default();

    let stages = thread::scope(|scope| {
        for _ in 0..options.read_parse_workers {
            let sender = sender.clone();
            let in_flight = Arc::clone(&in_flight);
            let peak_in_flight = Arc::clone(&peak_in_flight);
            let next_source = &next_source;
            scope.spawn(move || {
                loop {
                    let index = next_source.fetch_add(1, Ordering::Relaxed);
                    let Some(source) = sources.get(index) else {
                        break;
                    };
                    let result = read_parse_source_at(index, source);
                    let current_in_flight = in_flight.fetch_add(1, Ordering::AcqRel) + 1;
                    update_peak_in_flight(&peak_in_flight, current_in_flight);
                    if sender.send(result).is_err() {
                        in_flight.fetch_sub(1, Ordering::AcqRel);
                        break;
                    }
                }
            });
        }
        drop(sender);

        let documents = receiver.into_iter().map(|result| {
            in_flight.fetch_sub(1, Ordering::AcqRel);
            let timed = result?;
            stats.record_timed(&timed);
            Ok::<SearchDocument, IndexingPipelineError>(timed.document)
        });

        index.add_documents_for_rebuild_from_result_iter_with_options_and_stage_durations(
            documents,
            options.writer_options,
        )
    })?;

    Ok(TantivyPipelineRun {
        stats,
        peak_in_flight_items: peak_in_flight.load(Ordering::Acquire),
        stages,
    })
}

pub(crate) fn merge_tantivy_metrics(
    left: TantivyIndexingStageMetrics,
    right: TantivyIndexingStageMetrics,
) -> TantivyIndexingStageMetrics {
    TantivyIndexingStageMetrics {
        add_micros: left.add_micros + right.add_micros,
        commit_micros: left.commit_micros + right.commit_micros,
        reader_reload_micros: left.reader_reload_micros + right.reader_reload_micros,
        added_document_count: left.added_document_count + right.added_document_count,
        deleted_document_count: left.deleted_document_count + right.deleted_document_count,
        skipped_document_count: left.skipped_document_count + right.skipped_document_count,
        failed_document_count: left.failed_document_count + right.failed_document_count,
    }
}

fn update_peak_in_flight(peak: &AtomicUsize, candidate: usize) {
    let mut current = peak.load(Ordering::Acquire);
    while candidate > current {
        match peak.compare_exchange(current, candidate, Ordering::AcqRel, Ordering::Acquire) {
            Ok(_) => break,
            Err(observed) => current = observed,
        }
    }
}
