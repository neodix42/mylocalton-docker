# Shared jq helpers for run-native-benchmark.sh. Keep this file dependency-free
# so every report stage can load it with jq -L benchmark/jq.

# Preserve a present JSON false instead of treating it like a missing value.
def field_or_null($object; $field):
  if $object == null or (($object | type) != "object") or
     (($object | has($field)) | not)
  then null
  else $object[$field]
  end;

# Session Stats writes some native fast-path counters as boolean text. These
# are counters: true is one occurrence and false is zero.
def stat_counter_value:
  if type == "number" then .
  elif type == "boolean" then (if . then 1 else 0 end)
  elif type == "string" then
    if . == "true" then 1
    elif . == "false" then 0
    else (tonumber? // null)
    end
  else null
  end;

# The native collator emits its fast-path counters in the space-separated
# work_time_real_stats string.  Keep checkpoint-coalescing parsing here rather
# than in the wrapper so the complete, all-or-nothing contract is testable and
# older result bundles remain explicitly distinguishable from a zero-counter
# run.
def native_work_time_counter_values($rows; $name):
  [$rows[] |
    ((.work_time_real_stats? // "") |
     (capture("(?:^| )" + $name + "=(?<value>(?:[-+0-9.eE]+|true|false))")? | .value) |
     stat_counter_value) |
    select(. != null)];

# Native checkpoint groups are committed transactionally.  Counters below are
# additive across collated candidates except per-candidate maxima.
# Report null values for an old or mixed image instead of treating a missing
# telemetry field as a zero-value coalescing experiment.
def native_checkpoint_coalescing_summary($rows):
  [
    "native_checkpoint_groups",
    "native_checkpoint_group_entries",
    "native_checkpoint_group_fragments",
    "native_checkpoint_group_max_entries",
    "native_checkpoint_group_max_fragments",
    "native_checkpoint_flush_capacity",
    "native_checkpoint_flush_ingress",
    "native_checkpoint_flush_deadline",
    "native_checkpoint_flush_fanout",
    "native_checkpoint_flush_headroom",
    "native_checkpoint_flush_latency",
    "native_checkpoint_refill_continuations",
    "native_checkpoint_refill_expirations",
    "native_checkpoint_ingress_retentions",
    "native_checkpoint_ingress_retention_max_dirty_accounts",
    "native_checkpoint_rollbacks",
    "native_checkpoint_rollback_entries"
  ] as $fields |
  ($rows | length) as $records_total |
  (reduce $fields[] as $field ({};
    .[$field] = native_work_time_counter_values($rows; $field))) as $values |
  (
    ($records_total > 0) and
    ([ $fields[] | select(($values[.] | length) != $records_total) ] | length == 0)
  ) as $capture_complete |
  def total($field):
    if $capture_complete then ($values[$field] | add) else null end;
  def maximum($field):
    if $capture_complete then ($values[$field] | max) else null end;
  total("native_checkpoint_groups") as $groups |
  total("native_checkpoint_group_entries") as $entries |
  total("native_checkpoint_group_fragments") as $fragments |
  {
    semantics:(
      "native exact-checkpoint coalescing counters summed across collated " +
      "candidates; group maxima are maxima across candidates; missing or " +
      "mixed source telemetry is reported as unavailable"
    ),
    capture_complete:$capture_complete,
    records_total:$records_total,
    records_with_telemetry:(
      $values["native_checkpoint_groups"] | length
    ),
    native_checkpoint_groups:$groups,
    native_checkpoint_group_entries:$entries,
    native_checkpoint_group_fragments:$fragments,
    native_checkpoint_group_max_entries:maximum("native_checkpoint_group_max_entries"),
    native_checkpoint_group_max_fragments:maximum("native_checkpoint_group_max_fragments"),
    native_checkpoint_average_entries_per_group:(
      if $groups != null and $groups > 0 then $entries / $groups else null end
    ),
    native_checkpoint_average_fragments_per_group:(
      if $groups != null and $groups > 0 then $fragments / $groups else null end
    ),
    native_checkpoint_flush_capacity:total("native_checkpoint_flush_capacity"),
    native_checkpoint_flush_ingress:total("native_checkpoint_flush_ingress"),
    native_checkpoint_flush_deadline:total("native_checkpoint_flush_deadline"),
    native_checkpoint_flush_fanout:total("native_checkpoint_flush_fanout"),
    native_checkpoint_flush_headroom:total("native_checkpoint_flush_headroom"),
    native_checkpoint_flush_latency:total("native_checkpoint_flush_latency"),
    native_checkpoint_refill_continuations:total("native_checkpoint_refill_continuations"),
    native_checkpoint_refill_expirations:total("native_checkpoint_refill_expirations"),
    native_checkpoint_ingress_retentions:total("native_checkpoint_ingress_retentions"),
    native_checkpoint_ingress_retention_max_dirty_accounts:(
      maximum("native_checkpoint_ingress_retention_max_dirty_accounts")
    ),
    native_checkpoint_rollbacks:total("native_checkpoint_rollbacks"),
    native_checkpoint_rollback_entries:total("native_checkpoint_rollback_entries")
  };

# Attribute every delayed native microbatch entry to exactly one terminal
# collator decision.  The 19 reason counters and the three counters used for
# reconciliation are an atomic telemetry contract: old, partial, or mixed
# validator images report unavailable values rather than plausible zeroes.
#
# Prebatch requeues live outside native_microbatch_delayed.  Entry counters
# count decoded logical transfers, while work counters count physical input
# envelopes; they consequently have their own completeness boundary and must
# not be added to one another or to the delayed-entry reasons.
def native_collator_deferral_summary($rows):
  [
    "native_deferral_intake_deadline_idle_entries",
    "native_deferral_intake_deadline_fragment_entries",
    "native_deferral_checkpoint_deadline_rollback_entries",
    "native_deferral_checkpoint_hard_preflight_entries",
    "native_deferral_checkpoint_size_preflight_entries",
    "native_deferral_medium_timeout_entries",
    "native_deferral_candidate_headroom_entries",
    "native_deferral_candidate_size_guard_entries",
    "native_deferral_protocol_account_capacity_entries",
    "native_deferral_account_unavailable_entries",
    "native_deferral_account_balance_unrepresentable_entries",
    "native_deferral_state_invalid_fields_entries",
    "native_deferral_state_invalid_signature_entries",
    "native_deferral_state_nonce_mismatch_entries",
    "native_deferral_state_nonce_overflow_entries",
    "native_deferral_state_invalid_source_entries",
    "native_deferral_state_invalid_destination_entries",
    "native_deferral_state_insufficient_balance_entries",
    "native_deferral_state_balance_overflow_entries"
  ] as $reason_fields |
  [
    "native_microbatch_delayed",
    "native_checkpoint_rollback_entries",
    "native_deadline_deferred"
  ] as $reconciliation_fields |
  [
    "native_prebatch_protocol_capacity_requeue_works",
    "native_prebatch_protocol_capacity_requeue_entries",
    "native_prebatch_carryover_requeue_works",
    "native_prebatch_carryover_requeue_entries",
    "native_prebatch_scalar_decode_retry_works"
  ] as $prebatch_fields |
  ($rows | length) as $records_total |
  (reduce ($reason_fields + $reconciliation_fields + $prebatch_fields)[] as $field ({};
    .[$field] = native_work_time_counter_values($rows; $field))) as $values |
  (
    ($records_total > 0) and
    ([$reason_fields[], $reconciliation_fields[] |
      select(($values[.] | length) != $records_total)] | length == 0)
  ) as $capture_complete |
  (
    ($records_total > 0) and
    ([$prebatch_fields[] |
      select(($values[.] | length) != $records_total)] | length == 0)
  ) as $prebatch_capture_complete |
  def primary_total($field):
    if $capture_complete then ($values[$field] | add) else null end;
  def prebatch_total($field):
    if $prebatch_capture_complete then ($values[$field] | add) else null end;
  (
    if $capture_complete
    then [$reason_fields[] | ($values[.] | add)] | add
    else null
    end
  ) as $reason_entries_sum |
  primary_total("native_microbatch_delayed") as $delayed |
  primary_total("native_checkpoint_rollback_entries") as $checkpoint_rollbacks |
  primary_total("native_deadline_deferred") as $deadline_deferred |
  (
    if $capture_complete then
      primary_total("native_deferral_checkpoint_deadline_rollback_entries") +
      primary_total("native_deferral_checkpoint_hard_preflight_entries") +
      primary_total("native_deferral_checkpoint_size_preflight_entries")
    else null
    end
  ) as $checkpoint_reason_entries_sum |
  (
    if $capture_complete then
      primary_total("native_deferral_intake_deadline_fragment_entries") +
      primary_total("native_deferral_checkpoint_deadline_rollback_entries")
    else null
    end
  ) as $deadline_reason_entries_sum |
  ({
    semantics:(
      "native delayed-entry reasons summed across collated candidates; every " +
      "_entries counter counts logical transfers and the 19 reasons must " +
      "partition native_microbatch_delayed; missing or mixed source telemetry " +
      "is reported as unavailable"
    ),
    capture_complete:$capture_complete,
    records_total:$records_total,
    records_with_telemetry:(
      $values["native_deferral_intake_deadline_idle_entries"] | length
    ),
    native_microbatch_delayed:$delayed,
    reason_entries_sum:$reason_entries_sum,
    delayed_accounting_error:(
      if $capture_complete then $delayed - $reason_entries_sum else null end
    ),
    native_checkpoint_rollback_entries:$checkpoint_rollbacks,
    checkpoint_reason_entries_sum:$checkpoint_reason_entries_sum,
    checkpoint_accounting_error:(
      if $capture_complete
      then $checkpoint_rollbacks - $checkpoint_reason_entries_sum
      else null
      end
    ),
    native_deadline_deferred:$deadline_deferred,
    deadline_reason_entries_sum:$deadline_reason_entries_sum,
    deadline_accounting_error:(
      if $capture_complete
      then $deadline_deferred - $deadline_reason_entries_sum
      else null
      end
    ),
    totals_reconcile:(
      if $capture_complete then
        ($delayed == $reason_entries_sum) and
        ($checkpoint_rollbacks == $checkpoint_reason_entries_sum) and
        ($deadline_deferred == $deadline_reason_entries_sum)
      else null
      end
    )
  } +
  (reduce $reason_fields[] as $field ({};
    .[$field] = primary_total($field))) +
  {
    prebatch:({
      semantics:(
        "prebatch requeues summed across collated candidates and excluded from " +
        "native_microbatch_delayed; _entries count decoded logical transfers, " +
        "while _works count physical input envelopes and are not additive with entries"
      ),
      capture_complete:$prebatch_capture_complete,
      records_total:$records_total,
      records_with_telemetry:(
        $values["native_prebatch_protocol_capacity_requeue_works"] | length
      )
    } +
    (reduce $prebatch_fields[] as $field ({};
      .[$field] = prebatch_total($field))))
  });

# Summarize the exact immutable shard-state cache used by external-message
# admission. C13 names cache misses handed to ValidatorManager
# shard_manager_waits. C12 emitted the same logical event as shard_fetches, so
# complete C12 snapshots remain readable through that deprecated alias. Images
# predating the full cache contract still fail closed instead of mixing the
# original, unrelated meaning of shard_fetches into this view.
def native_admission_shard_cache_summary($before; $after):
  [
    "shard_state_requests",
    "shard_cache_hits",
    "shard_cache_fills",
    "shard_cache_fill_races",
    "shard_cache_fill_conflicts",
    "shard_cache_generation_resets",
    "shard_cache_stale_generation_fill_skips",
    "shard_cache_wrong_id",
    "shard_cache_invalid_header",
    "shard_cache_entries",
    "shard_cache_peak_entries"
  ] as $common_required |
  [
    "shard_manager_waits",
    "shard_fetches",
    "shard_miss_errors",
    "shard_fetch_errors",
    "shard_manager_wait_errors",
    "shard_manager_wait_timeouts",
    "shard_manager_wait_notready",
    "shard_manager_wait_other_errors",
    "shard_manager_wait_late_results"
  ] as $manager_wait_required |
  def both_have_numeric($field):
    (($before | type) == "object") and
    (($after | type) == "object") and
    ($before | has($field)) and
    ($after | has($field)) and
    (($before[$field] | stat_counter_value) != null) and
    (($after[$field] | stat_counter_value) != null);
  (
    (($before | type) == "object") and
    (($after | type) == "object") and
    all($common_required[]; both_have_numeric(.)) and
    (both_have_numeric("shard_manager_waits") or both_have_numeric("shard_fetches")) and
    (both_have_numeric("shard_miss_errors") or both_have_numeric("shard_fetch_errors"))
  ) as $complete |
  (all($manager_wait_required[]; both_have_numeric(.))) as $manager_wait_complete |
  if $complete then
    (if both_have_numeric("shard_manager_waits")
     then "shard_manager_waits"
     else "shard_fetches"
     end) as $manager_wait_field |
    (if both_have_numeric("shard_miss_errors")
     then "shard_miss_errors"
     else "shard_fetch_errors"
     end) as $miss_error_field |
    (($after.shard_state_requests | stat_counter_value) -
     ($before.shard_state_requests | stat_counter_value)) as $requests |
    (($after.shard_cache_hits | stat_counter_value) -
     ($before.shard_cache_hits | stat_counter_value)) as $hits |
    (($after[$manager_wait_field] | stat_counter_value) -
     ($before[$manager_wait_field] | stat_counter_value)) as $manager_waits |
    (($after[$miss_error_field] | stat_counter_value) -
     ($before[$miss_error_field] | stat_counter_value)) as $miss_errors |
    (($after.shard_cache_fills | stat_counter_value) -
     ($before.shard_cache_fills | stat_counter_value)) as $fills |
    (($after.shard_cache_fill_races | stat_counter_value) -
     ($before.shard_cache_fill_races | stat_counter_value)) as $fill_races |
    (($after.shard_cache_fill_conflicts | stat_counter_value) -
     ($before.shard_cache_fill_conflicts | stat_counter_value)) as $fill_conflicts |
    (($after.shard_cache_stale_generation_fill_skips | stat_counter_value) -
     ($before.shard_cache_stale_generation_fill_skips | stat_counter_value)) as $stale_fills |
    (if $manager_wait_complete then
       (($after.shard_manager_wait_errors | stat_counter_value) -
        ($before.shard_manager_wait_errors | stat_counter_value))
     else null
     end) as $manager_wait_errors |
    (if $manager_wait_complete then
       (($after.shard_manager_wait_timeouts | stat_counter_value) -
        ($before.shard_manager_wait_timeouts | stat_counter_value))
     else null
     end) as $manager_wait_timeouts |
    (if $manager_wait_complete then
       (($after.shard_manager_wait_notready | stat_counter_value) -
        ($before.shard_manager_wait_notready | stat_counter_value))
     else null
     end) as $manager_wait_notready |
    (if $manager_wait_complete then
       (($after.shard_manager_wait_other_errors | stat_counter_value) -
        ($before.shard_manager_wait_other_errors | stat_counter_value))
     else null
     end) as $manager_wait_other_errors |
    (if $manager_wait_complete then
       (($after.shard_manager_wait_late_results | stat_counter_value) -
        ($before.shard_manager_wait_late_results | stat_counter_value))
     else null
     end) as $manager_wait_late_results |
    {
      semantics:(
        "deltas for exact shard-view admission lookups; shard_manager_waits counts " +
        "logical cache misses handed to ValidatorManager and may include manager-cache " +
        "hits or exact-ID waiter joins, so it is not a physical backend-read count; " +
        "shard_fetches and shard_fetch_errors are deprecated compatibility aliases"
      ),
      capture_complete:true,
      counter_source:$manager_wait_field,
      manager_wait_outcomes_capture_complete:$manager_wait_complete,
      shard_state_requests:$requests,
      shard_cache_hits:$hits,
      shard_manager_waits:$manager_waits,
      shard_fetches:$manager_waits,
      hit_ratio:(if $requests > 0 then $hits / $requests else null end),
      manager_wait_ratio:(if $requests > 0 then $manager_waits / $requests else null end),
      fetch_ratio:(if $requests > 0 then $manager_waits / $requests else null end),
      request_accounting_error:($requests - $hits - $manager_waits),
      shard_cache_fills:$fills,
      shard_cache_fill_races:$fill_races,
      shard_cache_fill_conflicts:$fill_conflicts,
      shard_cache_generation_resets:(
        ($after.shard_cache_generation_resets | stat_counter_value) -
        ($before.shard_cache_generation_resets | stat_counter_value)
      ),
      shard_cache_stale_generation_fill_skips:$stale_fills,
      shard_cache_wrong_id:(
        ($after.shard_cache_wrong_id | stat_counter_value) -
        ($before.shard_cache_wrong_id | stat_counter_value)
      ),
      shard_cache_invalid_header:(
        ($after.shard_cache_invalid_header | stat_counter_value) -
        ($before.shard_cache_invalid_header | stat_counter_value)
      ),
      shard_miss_errors:$miss_errors,
      shard_fetch_errors:$miss_errors,
      shard_manager_wait_errors:$manager_wait_errors,
      shard_manager_wait_timeouts:$manager_wait_timeouts,
      shard_manager_wait_notready:$manager_wait_notready,
      shard_manager_wait_other_errors:$manager_wait_other_errors,
      shard_manager_wait_late_results:$manager_wait_late_results,
      shard_validation_or_store_errors:(
        if $manager_wait_complete then $miss_errors - $manager_wait_errors else null end
      ),
      manager_wait_outcome_accounting_error:(
        if $manager_wait_complete then
          $manager_waits - $fills - ($fill_races - $fill_conflicts) -
          $stale_fills - $miss_errors - $manager_wait_late_results
        else null
        end
      ),
      manager_wait_error_accounting_error:(
        if $manager_wait_complete then
          $manager_wait_errors - $manager_wait_timeouts - $manager_wait_notready -
          $manager_wait_other_errors
        else null
        end
      ),
      manager_wait_alias_consistent:(
        if $manager_wait_complete then
          (($before.shard_manager_waits | stat_counter_value) ==
           ($before.shard_fetches | stat_counter_value)) and
          (($after.shard_manager_waits | stat_counter_value) ==
           ($after.shard_fetches | stat_counter_value))
        else null
        end
      ),
      miss_error_alias_consistent:(
        if $manager_wait_complete then
          (($before.shard_miss_errors | stat_counter_value) ==
           ($before.shard_fetch_errors | stat_counter_value)) and
          (($after.shard_miss_errors | stat_counter_value) ==
           ($after.shard_fetch_errors | stat_counter_value))
        else null
        end
      ),
      shard_cache_entries_before:($before.shard_cache_entries | stat_counter_value),
      shard_cache_entries_after:($after.shard_cache_entries | stat_counter_value),
      shard_cache_peak_entries:($after.shard_cache_peak_entries | stat_counter_value)
    }
  else
    {
      semantics:(
        "deltas for exact shard-view admission lookups; shard_manager_waits counts " +
        "logical cache misses handed to ValidatorManager and may include manager-cache " +
        "hits or exact-ID waiter joins, so it is not a physical backend-read count; " +
        "shard_fetches and shard_fetch_errors are deprecated compatibility aliases"
      ),
      capture_complete:false,
      counter_source:null,
      manager_wait_outcomes_capture_complete:false,
      shard_state_requests:null,
      shard_cache_hits:null,
      shard_manager_waits:null,
      shard_fetches:null,
      hit_ratio:null,
      manager_wait_ratio:null,
      fetch_ratio:null,
      request_accounting_error:null,
      shard_cache_fills:null,
      shard_cache_fill_races:null,
      shard_cache_fill_conflicts:null,
      shard_cache_generation_resets:null,
      shard_cache_stale_generation_fill_skips:null,
      shard_cache_wrong_id:null,
      shard_cache_invalid_header:null,
      shard_miss_errors:null,
      shard_fetch_errors:null,
      shard_manager_wait_errors:null,
      shard_manager_wait_timeouts:null,
      shard_manager_wait_notready:null,
      shard_manager_wait_other_errors:null,
      shard_manager_wait_late_results:null,
      shard_validation_or_store_errors:null,
      manager_wait_outcome_accounting_error:null,
      manager_wait_error_accounting_error:null,
      manager_wait_alias_consistent:null,
      miss_error_alias_consistent:null,
      shard_cache_entries_before:null,
      shard_cache_entries_after:null,
      shard_cache_peak_entries:null
    }
  end;

# Reconcile the wall-clock external wait recorded on each collation with the
# ten mutually exclusive queue lifecycle categories. These fields are absent
# from work_time_cpu_stats by design. Legacy or mixed samples remain readable,
# but derived totals are null unless every selected collation has the complete
# new wall-clock field set.
def collation_external_wait_summary($rows):
  [
    {key:"round_live", seconds:"external_wait_round_live_s",
     calls:"external_wait_round_live_calls"},
    {key:"round_native_coalescing", seconds:"external_wait_round_native_coalescing_s",
     calls:"external_wait_round_native_coalescing_calls"},
    {key:"generic_try_pop", seconds:"external_wait_generic_try_pop_s",
     calls:"external_wait_generic_try_pop_calls"},
    {key:"generic_sync_snapshot", seconds:"external_wait_generic_sync_snapshot_s",
     calls:"external_wait_generic_sync_snapshot_calls"},
    {key:"native_probe", seconds:"external_wait_native_probe_s",
     calls:"external_wait_native_probe_calls"},
    {key:"native_first_work", seconds:"external_wait_native_first_work_s",
     calls:"external_wait_native_first_work_calls"},
    {key:"native_fragment_refill", seconds:"external_wait_native_fragment_refill_s",
     calls:"external_wait_native_fragment_refill_calls"},
    {key:"native_post_commit_idle", seconds:"external_wait_native_post_commit_idle_s",
     calls:"external_wait_native_post_commit_idle_calls"},
    {key:"native_producer_drain", seconds:"external_wait_native_producer_drain_s",
     calls:"external_wait_native_producer_drain_calls"},
    {key:"native_sync_snapshot", seconds:"external_wait_native_sync_snapshot_s",
     calls:"external_wait_native_sync_snapshot_calls"}
  ] as $category_fields |
  def numeric_or_null:
    if type == "number" then .
    elif type == "string" then (tonumber? // null)
    else null
    end;
  def work_stat($row; $name):
    (($row.work_time_real_stats? // "") |
      ((capture("(?:^| )" + $name +
                "=(?<value>(?:[-+0-9.eE]+|true|false))")? | .value) // null) |
      stat_counter_value);
  [
    $rows[] as $row |
    (work_stat($row; "external_wait_accounted_s")) as $accounted |
    (work_stat($row; "external_wait_calls")) as $external_calls |
    (reduce $category_fields[] as $field
      ({};
       .[$field.key] = {
         seconds:work_stat($row; $field.seconds),
         calls:work_stat($row; $field.calls)
       })) as $categories |
    {
      wait_externals_time:($row.wait_externals_time? | numeric_or_null),
      accounted:$accounted,
      external_calls:$external_calls,
      categories:$categories,
      telemetry_present:(
        ($accounted != null) or ($external_calls != null) or
        any($category_fields[];
          . as $field |
          ($categories[$field.key].seconds != null) or
          ($categories[$field.key].calls != null))
      ),
      complete:(
        (($row.wait_externals_time? | numeric_or_null) != null) and
        ($accounted != null) and ($external_calls != null) and
        all($category_fields[];
          . as $field |
          ($categories[$field.key].seconds != null) and
          ($categories[$field.key].calls != null))
      )
    }
  ] as $parsed |
  ([$parsed[] | select(.telemetry_present)] | length) as $with_telemetry |
  (($parsed | length) > 0 and
   $with_telemetry == ($parsed | length) and
   all($parsed[]; .complete)) as $complete |
  if $complete then
    ($parsed | map(.wait_externals_time) | add // 0) as $wait_total |
    ($parsed | map(.accounted) | add // 0) as $reported_accounted |
    ([
      $parsed[] as $row |
      ([$category_fields[].key as $key | $row.categories[$key].seconds] | add // 0) as
        $row_category_seconds |
      ($row_category_seconds - $row.wait_externals_time) as $row_accounting_error |
      ($row.accounted - $row.wait_externals_time) as $row_reported_accounting_error |
      ($row_category_seconds - $row.accounted) as $row_category_reported_error |
      ([0.0001, (($row.wait_externals_time | fabs) * 0.001)] | max) as $row_tolerance |
      ([
        ($row_accounting_error | fabs),
        ($row_reported_accounting_error | fabs),
        ($row_category_reported_error | fabs)
      ] | max) as $row_max_absolute_error |
      {
        tolerance:$row_tolerance,
        max_absolute_error:$row_max_absolute_error,
        within_tolerance:(
          (($row_accounting_error | fabs) <= $row_tolerance) and
          (($row_reported_accounting_error | fabs) <= $row_tolerance) and
          (($row_category_reported_error | fabs) <= $row_tolerance)
        )
      }
    ]) as $row_accounting |
    (reduce $category_fields[] as $field
      ({};
       .[$field.key] = {
         seconds:($parsed | map(.categories[$field.key].seconds) | add // 0),
         calls:($parsed | map(.categories[$field.key].calls) | add // 0)
       })) as $category_totals |
    ([$category_fields[].key as $key | $category_totals[$key].seconds] | add // 0) as
      $category_seconds |
    ([$category_fields[].key as $key | $category_totals[$key].calls] | add // 0) as
      $category_calls |
    ($parsed | map(.external_calls) | add // 0) as $external_calls_total |
    ($category_seconds - $wait_total) as $accounting_error |
    ($reported_accounted - $wait_total) as $reported_accounting_error |
    ($category_seconds - $reported_accounted) as $category_reported_error |
    {
      semantics:(
        "wall-clock-only external queue waits; the ten categories are mutually " +
        "exclusive and each record should reconcile to wait_externals_time within " +
        "max(100us, 0.1%); aggregate signed errors cannot hide a failing record"
      ),
      telemetry_available:true,
      capture_complete:true,
      records_total:($parsed | length),
      records_with_telemetry:$with_telemetry,
      wait_externals_total_s:$wait_total,
      reported_accounted_total_s:$reported_accounted,
      category_total_s:$category_seconds,
      accounting_error_s:$accounting_error,
      reported_accounting_error_s:$reported_accounting_error,
      category_vs_reported_accounted_error_s:$category_reported_error,
      absolute_accounting_error_s:($accounting_error | fabs),
      accounting_tolerance_envelope_s:($row_accounting | map(.tolerance) | add // 0),
      max_per_record_absolute_accounting_error_s:($row_accounting | map(.max_absolute_error) | max // null),
      accounting_within_tolerance:all($row_accounting[]; .within_tolerance),
      external_wait_calls:$external_calls_total,
      category_calls:$category_calls,
      call_accounting_error:($category_calls - $external_calls_total),
      categories:(reduce $category_fields[] as $field
        ({};
         .[$field.key] = ($category_totals[$field.key] + {
           fraction_of_accounted:(
             if $reported_accounted > 0
             then $category_totals[$field.key].seconds / $reported_accounted
             else null
             end
           )
         })))
    }
  else
    {
      semantics:(
        "wall-clock-only external queue waits; the ten categories are mutually " +
        "exclusive and each record should reconcile to wait_externals_time within " +
        "max(100us, 0.1%); aggregate signed errors cannot hide a failing record"
      ),
      telemetry_available:($with_telemetry > 0),
      capture_complete:false,
      records_total:($parsed | length),
      records_with_telemetry:$with_telemetry,
      wait_externals_total_s:null,
      reported_accounted_total_s:null,
      category_total_s:null,
      accounting_error_s:null,
      reported_accounting_error_s:null,
      category_vs_reported_accounted_error_s:null,
      absolute_accounting_error_s:null,
      accounting_tolerance_envelope_s:null,
      max_per_record_absolute_accounting_error_s:null,
      accounting_within_tolerance:null,
      external_wait_calls:null,
      category_calls:null,
      call_accounting_error:null,
      categories:(reduce $category_fields[] as $field
        ({}; .[$field.key] = {seconds:null,calls:null,fraction_of_accounted:null}))
    }
  end;

# Sum deltas across monotonic counter segments. A lower sample starts a new
# segment (for example after a container restart), whose current value is its
# delta from zero. A final all-zero sample cannot erase the preceding segment.
def monotonic_counter_delta:
  [ .[] | select(type == "number") ] as $values |
  if ($values | length) < 2 then 0
  else
    reduce $values[1:][] as $current
      ({previous:$values[0], delta:0};
       .delta += (if $current >= .previous
                  then $current - .previous
                  else $current
                  end) |
       .previous = $current) |
    .delta
  end;

# `get-actor-stats` is intentionally text, not TL JSON. Parse only the stable
# per-type fields needed to diagnose an actor monopolizing a scheduler thread.
# A missing/changed block returns null so this best-effort diagnostic can never
# weaken the benchmark's proof or cleanup acceptance decisions.
def validator_actor_stats_actor_types:
  def actor_stat_number:
    if type == "string" then (sub("s$"; "") | tonumber?) else null end;
  def actor_stat_triplet($name):
    capture("^[\\t ]*" + $name +
            ":?[\\t ]*(?<last_10s>[^\\t ]+)[\\t ]+" +
            "(?<last_10m>[^\\t ]+)[\\t ]+" +
            "(?<lifetime>[^\\t ]+)[\\t ]*$") |
    with_entries(.value |= actor_stat_number);
  reduce (split("\n")[]) as $line
    ({in_all_actors:false,current_actor_key:null,overlay_impl:null,decryptor_async:null,
      actor_mailbox_quantum_yield_qps:null,
      overlay_traffic_fairness_yield_qps:null,
      overlay_fec_generated_callback_qps:null,
      overlay_fec_signed_callback_qps:null,
      overlay_fec_fairness_yield_qps:null};
     if ($line | test("^[\\t ]*actor_mailbox_quantum_yield[.]qps:?[\\t ]")) then
       .actor_mailbox_quantum_yield_qps = (
         $line | actor_stat_triplet("actor_mailbox_quantum_yield[.]qps")
       )
     elif ($line | test("^[\\t ]*overlay_traffic_fairness_yield[.]qps:?[\\t ]")) then
       .overlay_traffic_fairness_yield_qps = (
         $line | actor_stat_triplet("overlay_traffic_fairness_yield[.]qps")
       )
     elif ($line | test("^[\\t ]*overlay_fec_generated_callback[.]qps:?[\\t ]")) then
       .overlay_fec_generated_callback_qps = (
         $line | actor_stat_triplet("overlay_fec_generated_callback[.]qps")
       )
     elif ($line | test("^[\\t ]*overlay_fec_signed_callback[.]qps:?[\\t ]")) then
       .overlay_fec_signed_callback_qps = (
         $line | actor_stat_triplet("overlay_fec_signed_callback[.]qps")
       )
     elif ($line | test("^[\\t ]*overlay_fec_fairness_yield[.]qps:?[\\t ]")) then
       .overlay_fec_fairness_yield_qps = (
         $line | actor_stat_triplet("overlay_fec_fairness_yield[.]qps")
       )
     elif $line == "All actors:" then
       .in_all_actors = true
     elif .in_all_actors and ($line | test("^\\t[^\\t]")) then
       ($line | ltrimstr("\t") | sub("[\\t ]+$"; "")) as $actor_type |
       (if $actor_type == "OverlayImpl" or ($actor_type | endswith("::OverlayImpl")) then
          "overlay_impl"
        elif $actor_type == "DecryptorAsync" or ($actor_type | endswith("::DecryptorAsync")) then
          "decryptor_async"
        else null end) as $actor_key |
       .current_actor_key = $actor_key |
       if $actor_key != null and .[$actor_key] == null then
         .[$actor_key] = {actor_type:$actor_type}
       else . end
     elif .current_actor_key != null and ($line | test("^[\\t ]*load_per_second:")) then
       .current_actor_key as $actor_key |
       .[$actor_key].load_per_second = ($line | actor_stat_triplet("load_per_second"))
     elif .current_actor_key != null and ($line | test("^[\\t ]*messages_per_second:")) then
       .current_actor_key as $actor_key |
       .[$actor_key].messages_per_second = ($line | actor_stat_triplet("messages_per_second"))
     elif .current_actor_key != null and ($line | test("^[\\t ]*max_execute_messages:")) then
       .current_actor_key as $actor_key |
       .[$actor_key].max_execute_messages = ($line | actor_stat_triplet("max_execute_messages"))
     elif .current_actor_key != null and ($line | test("^[\\t ]*max_execute_seconds:")) then
       .current_actor_key as $actor_key |
       .[$actor_key].max_execute_seconds = ($line | actor_stat_triplet("max_execute_seconds"))
     elif .current_actor_key != null and ($line | test("^[\\t ]*max_message_seconds:")) then
       .current_actor_key as $actor_key |
       .[$actor_key].max_message_seconds = ($line | actor_stat_triplet("max_message_seconds"))
     elif .current_actor_key != null and ($line | test("^[\\t ]*max_delay:")) then
       .current_actor_key as $actor_key |
       .[$actor_key].max_delay_seconds = ($line | actor_stat_triplet("max_delay"))
     elif .current_actor_key != null and ($line | test("^[\\t ]*alive:")) then
       ($line | capture(
         "^[\\t ]*alive:[\\t ]*(?<alive>[0-9]+)[\\t ]+" +
         "executing:[\\t ]*(?<executing>[0-9]+)[\\t ]+" +
         "max_executing_for:[\\t ]*(?<max_executing_for_seconds>[^\\t ]+)[\\t ]*$"
       ) | with_entries(.value |= actor_stat_number)) as $state |
       .current_actor_key as $actor_key |
       .[$actor_key] += $state
     else . end) |
  {
    overlay_impl:(
      if .overlay_impl == null then null
      else .overlay_impl + {
        actor_mailbox_quantum_yield_qps:.actor_mailbox_quantum_yield_qps,
        overlay_traffic_fairness_yield_qps:.overlay_traffic_fairness_yield_qps,
        overlay_fec_generated_callback_qps:.overlay_fec_generated_callback_qps,
        overlay_fec_signed_callback_qps:.overlay_fec_signed_callback_qps,
        overlay_fec_fairness_yield_qps:.overlay_fec_fairness_yield_qps
      } end
    ),
    decryptor_async:.decryptor_async
  };

# Compatibility views for callers that consume one actor type directly.
def validator_actor_stats_overlay_impl:
  validator_actor_stats_actor_types | .overlay_impl;

def validator_actor_stats_decryptor_async:
  validator_actor_stats_actor_types | .decryptor_async;

def validator_actor_stats_summary($periodic; $pre_load; $final; $configuration):
  def numeric_max_or_null:
    map(select(type == "number")) |
    if length > 0 then max else null end;
  def overlay_maxima($rows):
    {
      load_per_second_10s:([$rows[].overlay_impl.load_per_second.last_10s] |
                           numeric_max_or_null),
      load_per_second_10m:([$rows[].overlay_impl.load_per_second.last_10m] |
                           numeric_max_or_null),
      max_execute_messages_10s:([$rows[].overlay_impl.max_execute_messages.last_10s] |
                                numeric_max_or_null),
      max_execute_messages_10m:([$rows[].overlay_impl.max_execute_messages.last_10m] |
                                numeric_max_or_null),
      max_execute_messages_lifetime:([$rows[].overlay_impl.max_execute_messages.lifetime] |
                                     numeric_max_or_null),
      max_execute_seconds_10s:([$rows[].overlay_impl.max_execute_seconds.last_10s] |
                               numeric_max_or_null),
      max_execute_seconds_10m:([$rows[].overlay_impl.max_execute_seconds.last_10m] |
                               numeric_max_or_null),
      max_execute_seconds_lifetime:([$rows[].overlay_impl.max_execute_seconds.lifetime] |
                                    numeric_max_or_null),
      max_message_seconds_10s:([$rows[].overlay_impl.max_message_seconds.last_10s] |
                               numeric_max_or_null),
      max_message_seconds_10m:([$rows[].overlay_impl.max_message_seconds.last_10m] |
                               numeric_max_or_null),
      max_message_seconds_lifetime:([$rows[].overlay_impl.max_message_seconds.lifetime] |
                                    numeric_max_or_null),
      max_delay_seconds_10s:([$rows[].overlay_impl.max_delay_seconds.last_10s] |
                             numeric_max_or_null),
      max_delay_seconds_10m:([$rows[].overlay_impl.max_delay_seconds.last_10m] |
                             numeric_max_or_null),
      max_delay_seconds_lifetime:([$rows[].overlay_impl.max_delay_seconds.lifetime] |
                                  numeric_max_or_null),
      max_executing_for_seconds:([$rows[].overlay_impl.max_executing_for_seconds] |
                                 numeric_max_or_null),
      actor_mailbox_quantum_yield_qps_10s:(
        [$rows[].overlay_impl.actor_mailbox_quantum_yield_qps.last_10s] |
        numeric_max_or_null
      ),
      actor_mailbox_quantum_yield_qps_10m:(
        [$rows[].overlay_impl.actor_mailbox_quantum_yield_qps.last_10m] |
        numeric_max_or_null
      ),
      actor_mailbox_quantum_yield_qps_lifetime:(
        [$rows[].overlay_impl.actor_mailbox_quantum_yield_qps.lifetime] |
        numeric_max_or_null
      ),
      overlay_traffic_fairness_yield_qps_10s:(
        [$rows[].overlay_impl.overlay_traffic_fairness_yield_qps.last_10s] |
        numeric_max_or_null
      ),
      overlay_traffic_fairness_yield_qps_10m:(
        [$rows[].overlay_impl.overlay_traffic_fairness_yield_qps.last_10m] |
        numeric_max_or_null
      ),
      overlay_traffic_fairness_yield_qps_lifetime:(
        [$rows[].overlay_impl.overlay_traffic_fairness_yield_qps.lifetime] |
        numeric_max_or_null
      ),
      overlay_fec_generated_callback_qps_10s:(
        [$rows[].overlay_impl.overlay_fec_generated_callback_qps.last_10s] |
        numeric_max_or_null
      ),
      overlay_fec_generated_callback_qps_10m:(
        [$rows[].overlay_impl.overlay_fec_generated_callback_qps.last_10m] |
        numeric_max_or_null
      ),
      overlay_fec_generated_callback_qps_lifetime:(
        [$rows[].overlay_impl.overlay_fec_generated_callback_qps.lifetime] |
        numeric_max_or_null
      ),
      overlay_fec_signed_callback_qps_10s:(
        [$rows[].overlay_impl.overlay_fec_signed_callback_qps.last_10s] |
        numeric_max_or_null
      ),
      overlay_fec_signed_callback_qps_10m:(
        [$rows[].overlay_impl.overlay_fec_signed_callback_qps.last_10m] |
        numeric_max_or_null
      ),
      overlay_fec_signed_callback_qps_lifetime:(
        [$rows[].overlay_impl.overlay_fec_signed_callback_qps.lifetime] |
        numeric_max_or_null
      ),
      overlay_fec_fairness_yield_qps_10s:(
        [$rows[].overlay_impl.overlay_fec_fairness_yield_qps.last_10s] |
        numeric_max_or_null
      ),
      overlay_fec_fairness_yield_qps_10m:(
        [$rows[].overlay_impl.overlay_fec_fairness_yield_qps.last_10m] |
        numeric_max_or_null
      ),
      overlay_fec_fairness_yield_qps_lifetime:(
        [$rows[].overlay_impl.overlay_fec_fairness_yield_qps.lifetime] |
        numeric_max_or_null
      ),
      max_alive:([$rows[].overlay_impl.alive] | numeric_max_or_null),
      max_executing:([$rows[].overlay_impl.executing] | numeric_max_or_null)
    };
  def decryptor_async_maxima($rows):
    {
      load_per_second_10s:([$rows[].decryptor_async.load_per_second.last_10s] |
                           numeric_max_or_null),
      load_per_second_10m:([$rows[].decryptor_async.load_per_second.last_10m] |
                           numeric_max_or_null),
      load_per_second_lifetime:([$rows[].decryptor_async.load_per_second.lifetime] |
                                numeric_max_or_null),
      messages_per_second_10s:([$rows[].decryptor_async.messages_per_second.last_10s] |
                               numeric_max_or_null),
      messages_per_second_10m:([$rows[].decryptor_async.messages_per_second.last_10m] |
                               numeric_max_or_null),
      messages_per_second_lifetime:([$rows[].decryptor_async.messages_per_second.lifetime] |
                                    numeric_max_or_null),
      max_execute_messages_10s:([$rows[].decryptor_async.max_execute_messages.last_10s] |
                                numeric_max_or_null),
      max_execute_messages_10m:([$rows[].decryptor_async.max_execute_messages.last_10m] |
                                numeric_max_or_null),
      max_execute_messages_lifetime:([$rows[].decryptor_async.max_execute_messages.lifetime] |
                                     numeric_max_or_null),
      max_execute_seconds_10s:([$rows[].decryptor_async.max_execute_seconds.last_10s] |
                               numeric_max_or_null),
      max_execute_seconds_10m:([$rows[].decryptor_async.max_execute_seconds.last_10m] |
                               numeric_max_or_null),
      max_execute_seconds_lifetime:([$rows[].decryptor_async.max_execute_seconds.lifetime] |
                                    numeric_max_or_null),
      max_message_seconds_10s:([$rows[].decryptor_async.max_message_seconds.last_10s] |
                               numeric_max_or_null),
      max_message_seconds_10m:([$rows[].decryptor_async.max_message_seconds.last_10m] |
                               numeric_max_or_null),
      max_message_seconds_lifetime:([$rows[].decryptor_async.max_message_seconds.lifetime] |
                                    numeric_max_or_null),
      max_delay_seconds_10s:([$rows[].decryptor_async.max_delay_seconds.last_10s] |
                             numeric_max_or_null),
      max_delay_seconds_10m:([$rows[].decryptor_async.max_delay_seconds.last_10m] |
                             numeric_max_or_null),
      max_delay_seconds_lifetime:([$rows[].decryptor_async.max_delay_seconds.lifetime] |
                                  numeric_max_or_null),
      max_executing_for_seconds:([$rows[].decryptor_async.max_executing_for_seconds] |
                                 numeric_max_or_null),
      max_alive:([$rows[].decryptor_async.alive] | numeric_max_or_null),
      max_executing:([$rows[].decryptor_async.executing] | numeric_max_or_null)
    };
  [$periodic[] | select((.overlay_impl // null) != null)] as $overlay_parsed |
  [$periodic[] | select((.decryptor_async // null) != null)] as $decryptor_parsed |
  ($periodic | map(.command_duration_seconds // 0) | add // 0) as $periodic_wall |
  ($configuration.load_window_seconds // 0) as $load_window |
  {
    schema:"native-benchmark-validator-actor-stats-summary-v1",
    semantics:(
      "best-effort serialized validator get-actor-stats samples; actor counters are " +
      "diagnostic and do not participate in benchmark acceptance"
    ),
    configuration:$configuration,
    periodic:{
      samples:($periodic | length),
      successful_queries:([$periodic[] | select(.command_exit_code == 0)] | length),
      parsed_overlay_impl_samples:($overlay_parsed | length),
      parsed_decryptor_async_samples:($decryptor_parsed | length),
      timed_out_queries:([$periodic[] | select(.timed_out == true)] | length),
      failed_queries:([$periodic[] | select(.command_exit_code != 0)] | length),
      first_started_at:($periodic[0].started_at // null),
      last_finished_at:($periodic[-1].finished_at // null),
      total_command_wall_seconds:$periodic_wall,
      max_command_wall_seconds:([$periodic[].command_duration_seconds] |
                                numeric_max_or_null),
      observed_load_window_query_wall_fraction:(
        if $load_window > 0 then $periodic_wall / $load_window else null end
      )
    },
    perturbation_bound:{
      serialized_no_overlap:true,
      command_calls_total:(
        ($periodic | length) +
        (if ($pre_load | type) == "object" then 1 else 0 end) +
        (if ($final | type) == "object" then 1 else 0 end)
      ),
      total_command_wall_seconds:(
        $periodic_wall + ($pre_load.command_duration_seconds // 0) +
        ($final.command_duration_seconds // 0)
      ),
      pre_load_command_wall_seconds:($pre_load.command_duration_seconds // null),
      post_drain_command_wall_seconds:($final.command_duration_seconds // null),
      validator_query_timeout_seconds:($configuration.command_timeout_seconds // null),
      host_docker_exec_guard_seconds:($configuration.host_guard_seconds // null),
      configured_max_validator_query_wall_fraction:(
        if (($configuration.sample_interval_seconds // 0) > 0) then
          ($configuration.command_timeout_seconds // 0) /
          $configuration.sample_interval_seconds
        else null end
      ),
      note:(
        "the server-side timeout bounds each validator-console process; a separate " +
        "host guard only prevents a stuck docker exec client"
      )
    },
    overlay_impl:{
      parsed_periodic_samples:($overlay_parsed | length),
      periodic_maxima:overlay_maxima($overlay_parsed),
      peak_max_execute_seconds_10m_sample:(
        if ($overlay_parsed | length) == 0 then null
        else
          ($overlay_parsed | max_by(.overlay_impl.max_execute_seconds.last_10m // -1)) |
          {sequence,started_at,finished_at,command_duration_seconds,overlay_impl}
        end
      )
    },
    decryptor_async:{
      parsed_periodic_samples:($decryptor_parsed | length),
      periodic_maxima:decryptor_async_maxima($decryptor_parsed),
      peak_max_execute_seconds_10m_sample:(
        if ($decryptor_parsed | length) == 0 then null
        else
          ($decryptor_parsed | max_by(.decryptor_async.max_execute_seconds.last_10m // -1)) |
          {sequence,started_at,finished_at,command_duration_seconds,decryptor_async}
        end
      )
    },
    pre_load_snapshot:{
      raw_artifact:($configuration.pre_load_raw_artifact // null),
      capture:($pre_load // null),
      overlay_impl:($pre_load.overlay_impl // null),
      decryptor_async:($pre_load.decryptor_async // null)
    },
    measure_end_snapshot:(
      [$periodic[] | select(.phase == "measure_end")] | first // null
    ),
    final_snapshot:{
      raw_artifact:($configuration.final_raw_artifact // null),
      capture:($final // null),
      overlay_impl:($final.overlay_impl // null),
      decryptor_async:($final.decryptor_async // null)
    }
  };

# Retain the generator's proof-derived object verbatim while also exposing the
# deterministic lane array directly in the generator summary for consumers.
def canonical_lane_balance_telemetry($final):
  field_or_null($final; "canonical_lane_balance") as $balance |
  {
    canonical_lane_balance:$balance,
    canonical_lanes:(
      if ($balance | type) == "object" then field_or_null($balance; "lanes")
      else null
      end
    )
  };

# Independently validate the concrete depth-2 lane rows. This prevents a
# self-inconsistent producer from turning forged summary booleans into a
# capacity pass. All arithmetic is over nonnegative integer transfer counts.
def canonical_depth2_lane_record_checks($balance):
  field_or_null($balance; "lanes") as $lanes |
  (($lanes | type) == "array") as $array_valid |
  (if $array_valid then (($lanes | length) == 4) else false end) as $lane_count_valid |
  (if $array_valid then
     all($lanes[];
       . as $lane |
       field_or_null($lane; "shard") as $shard |
       field_or_null($lane; "measured_native_transfers") as $transfers |
       ($lane | type) == "object" and
       ($shard | type) == "string" and ($shard | length) > 0 and
       ($transfers | type) == "number" and $transfers >= 0 and
       ($transfers | floor) == $transfers)
   else false
   end) as $records_valid |
  (if $records_valid then
     ([$lanes[].shard] | unique | length) == ($lanes | length)
   else false
   end) as $unique_shards |
  (if $records_valid then all($lanes[]; field_or_null(.; "depth") == 2)
   else false
   end) as $record_depths_valid |
  (if $records_valid then all($lanes[]; .measured_native_transfers > 0)
   else false
   end) as $every_lane_active |
  (if $records_valid then ([$lanes[].measured_native_transfers] | add // 0)
   else null
   end) as $measured_transfers_sum |
  field_or_null($balance; "measured_transfers") as $aggregate_transfers |
  field_or_null($balance; "lane_measured_transfers_sum") as $reported_lane_sum |
  ($records_valid and
   ($aggregate_transfers | type) == "number" and $aggregate_transfers >= 0 and
   ($aggregate_transfers | floor) == $aggregate_transfers and
   ($reported_lane_sum | type) == "number" and $reported_lane_sum >= 0 and
   ($reported_lane_sum | floor) == $reported_lane_sum and
   $measured_transfers_sum == $aggregate_transfers and
   $measured_transfers_sum == $reported_lane_sum) as $totals_reconcile |
  (if $records_valid and $measured_transfers_sum > 0 then
     all($lanes[];
       (.measured_native_transfers * 4 * 10000) >=
         ($measured_transfers_sum * 9500) and
       (.measured_native_transfers * 4 * 10000) <=
         ($measured_transfers_sum * 10500))
   else false
   end) as $within_tolerance |
  {
    array_valid:$array_valid,
    lane_count_valid:$lane_count_valid,
    records_valid:$records_valid,
    unique_shards:$unique_shards,
    record_depths_valid:$record_depths_valid,
    every_lane_active:$every_lane_active,
    measured_transfers_sum:$measured_transfers_sum,
    totals_reconcile:$totals_reconcile,
    within_tolerance:$within_tolerance
  };

# A four-lane depth-2 result is only a capacity result when the proof follower
# observed useful canonical work in every fixed lane.  Depth 0/1 records
# predate this acceptance dimension, so their missing balance telemetry is
# deliberately not applicable rather than a retroactive failure.
def canonical_lane_balance_acceptance($final):
  if $final == null then
    {
      canonical_lane_balance_required:null,
      canonical_lane_balance_valid:null,
      canonical_lane_balance_invalid_reasons:["missing_final_generator_record"]
    }
  elif field_or_null($final; "native_payment_lane_depth") != 2 then
    {
      canonical_lane_balance_required:false,
      canonical_lane_balance_valid:null,
      canonical_lane_balance_invalid_reasons:[]
    }
  else
    field_or_null($final; "canonical_lane_balance") as $balance |
    if ($balance | type) != "object" then
      {
        canonical_lane_balance_required:true,
        canonical_lane_balance_valid:false,
        canonical_lane_balance_invalid_reasons:["canonical_lane_balance_missing"]
      }
    else
      canonical_depth2_lane_record_checks($balance) as $lane_records |
      (field_or_null($balance; "depth") == 2) as $depth_valid |
      (field_or_null($balance; "tolerance_bps") == 500) as $tolerance_valid |
      (field_or_null($balance; "expected_lanes") == 4) as $expected_count_valid |
      (field_or_null($balance; "observed_lanes") == 4) as $observed_count_valid |
      (field_or_null($balance; "required") == true and
       field_or_null($balance; "topology_complete") == true and
       field_or_null($balance; "totals_reconcile") == true and
       field_or_null($balance; "every_lane_active") == true and
       field_or_null($balance; "within_tolerance") == true and
       field_or_null($balance; "valid") == true and
       $depth_valid and $tolerance_valid and
       $expected_count_valid and $observed_count_valid and
       $lane_records.lane_count_valid and $lane_records.records_valid and
       $lane_records.unique_shards and $lane_records.record_depths_valid and
       $lane_records.every_lane_active and $lane_records.totals_reconcile and
       $lane_records.within_tolerance) as $valid |
      {
        canonical_lane_balance_required:true,
        canonical_lane_balance_valid:$valid,
        canonical_lane_balance_invalid_reasons:(if $valid then [] else [
          if field_or_null($balance; "required") != true
          then "canonical_lane_balance_not_required" else empty end,
          if field_or_null($balance; "topology_complete") != true
          then "canonical_lane_topology_incomplete" else empty end,
          if field_or_null($balance; "totals_reconcile") != true
          then "canonical_lane_totals_mismatch" else empty end,
          if field_or_null($balance; "every_lane_active") != true
          then "canonical_lane_inactive" else empty end,
          if field_or_null($balance; "within_tolerance") != true
          then "canonical_lane_imbalance" else empty end,
          if field_or_null($balance; "valid") != true
          then "canonical_lane_balance_invalid" else empty end,
          if $depth_valid | not
          then "canonical_lane_balance_depth_mismatch" else empty end,
          if $tolerance_valid | not
          then "canonical_lane_balance_tolerance_mismatch" else empty end,
          if $expected_count_valid | not
          then "canonical_lane_balance_expected_lanes_mismatch" else empty end,
          if $observed_count_valid | not
          then "canonical_lane_balance_observed_lanes_mismatch" else empty end,
          if $lane_records.lane_count_valid | not
          then "canonical_lane_balance_lane_records_mismatch" else empty end,
          if $lane_records.array_valid and ($lane_records.records_valid | not)
          then "canonical_lane_balance_lane_record_invalid" else empty end,
          if $lane_records.records_valid and ($lane_records.unique_shards | not)
          then "canonical_lane_balance_duplicate_shard" else empty end,
          if $lane_records.records_valid and ($lane_records.record_depths_valid | not)
          then "canonical_lane_balance_lane_depth_mismatch" else empty end,
          if $lane_records.records_valid and ($lane_records.every_lane_active | not)
          then "canonical_lane_balance_inactive_record" else empty end,
          if $lane_records.records_valid and ($lane_records.totals_reconcile | not)
          then "canonical_lane_balance_record_sum_mismatch" else empty end,
          if $lane_records.records_valid and ($lane_records.within_tolerance | not)
          then "canonical_lane_balance_record_share_outside_tolerance" else empty end
        ] end)
      }
    end
  end;

# Lift the generator's independent acceptance dimensions into the report
# without weakening its proof/capacity contract. For depth 2, canonical lane
# balance is an additional independent decision and a prerequisite for an
# effective chain-capacity pass. Older depth-0/1 output remains compatible.
def capacity_acceptance($final):
  if $final == null then
    {
      chain_correctness_valid:null,
      correctness_invalid_reasons:["missing_final_generator_record"],
      run_complete:null,
      run_incomplete_reasons:["missing_final_generator_record"],
      ingress_capacity_valid:null,
      ingress_capacity_invalid_reasons:["missing_final_generator_record"],
      chain_capacity_valid:null,
      chain_capacity_invalid_reasons:["missing_final_generator_record"]
    } + canonical_lane_balance_acceptance($final)
  else
    canonical_lane_balance_acceptance($final) as $lane_balance |
    ($final.chain_capacity_invalid_reasons // [] |
     if type == "array" then . else [] end) as $reported_chain_reasons |
    (if $lane_balance.canonical_lane_balance_required == true and
        $lane_balance.canonical_lane_balance_valid != true then
       reduce $lane_balance.canonical_lane_balance_invalid_reasons[] as $reason
         ($reported_chain_reasons;
          if index($reason) == null then . + [$reason] else . end)
     else $reported_chain_reasons
     end) as $chain_reasons |
    {
      chain_correctness_valid:field_or_null($final; "chain_correctness_valid"),
      correctness_invalid_reasons:($final.correctness_invalid_reasons // []),
      run_complete:(
        if ($final | has("run_incomplete_reasons"))
        then (($final.run_incomplete_reasons | length) == 0)
        else null
        end
      ),
      run_incomplete_reasons:($final.run_incomplete_reasons // []),
      ingress_capacity_valid:field_or_null($final; "ingress_capacity_valid"),
      ingress_capacity_invalid_reasons:($final.ingress_capacity_invalid_reasons // []),
      chain_capacity_valid:(
        if $lane_balance.canonical_lane_balance_required == true and
           $lane_balance.canonical_lane_balance_valid != true then false
        else field_or_null($final; "chain_capacity_valid")
        end
      ),
      chain_capacity_invalid_reasons:$chain_reasons
    } + $lane_balance
  end;

# Validator cleanup is a separate acceptance boundary from the generator's
# proof follower.  Missing getstats snapshots must fail closed: otherwise an
# old validator image (or a failed console query) could silently make the new
# canonical-only reconciliation invariant disappear from the report.
def validator_pool_cleanup_acceptance($reconciliation_after; $pending_after):
  ([
    if (($reconciliation_after | type) != "object") or
       (($reconciliation_after | length) == 0) or
       (($reconciliation_after | has("pending_sources")) | not)
    then "canonical_reconciliation_capture_missing"
    elif ($reconciliation_after.pending_sources != 0)
    then "canonical_reconciliation_pending_sources"
    else empty
    end,
    if (($pending_after | type) != "object") or
       (($pending_after | length) == 0) or
       (($pending_after | has("messages")) | not)
    then "native_pending_capture_missing"
    elif ($pending_after.messages != 0)
    then "native_pool_pending_messages"
    else empty
    end
  ]) as $reasons |
  {
    valid:(($reasons | length) == 0),
    invalid_reasons:$reasons
  };

# Preserve every native transport field for forensic use, emit arithmetic
# between-snapshot deltas, and keep lifetime maxima as observed values instead
# of pretending they reset at the measurement boundary.
def native_transport_summary($before; $after):
  ["high_water", "max_push_batch", "max_pop_batch"] as $observed_fields |
  def delta:
    if (($before | type) != "object") or (($after | type) != "object") then {}
    else reduce ($after | keys_unsorted[]) as $key ({};
      if ($observed_fields | index($key)) != null then .
      else .[$key] = (($after[$key] // 0) - ($before[$key] // 0))
      end)
    end;
  {
    semantics:(
      "ExtMessagePool native transport telemetry sampled immediately before and " +
      "after generator execution; high-water and maximum batch sizes are " +
      "validator-lifetime observations, while delta is the between-snapshot " +
      "arithmetic change for every other reported field"
    ),
    capture_complete:(
      (($before | type) == "object") and (($before | length) > 0) and
      (($after | type) == "object") and (($after | length) > 0)
    ),
    before:$before,
    after:$after,
    delta:delta,
    observed_high_water:field_or_null($after; "high_water"),
    observed_max_push_batch:field_or_null($after; "max_push_batch"),
    observed_max_pop_batch:field_or_null($after; "max_pop_batch")
  };
