//! Block validator
//!
//! The block validator checks whether all the deploys included in the block payload exist, either
//! locally or on the network.
//!
//! When multiple requests are made to validate the same block payload, they will eagerly return
//! true if valid, but only fail if all sources have been exhausted. This is only relevant when
//! calling for validation of the same protoblock multiple times at the same time.

mod keyed_counter;
#[cfg(test)]
mod tests;

use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    convert::Infallible,
    fmt::Debug,
    hash::Hash,
    marker::PhantomData,
    sync::Arc,
};

use datasize::DataSize;
use derive_more::{Display, From};
use itertools::Itertools;
use smallvec::{smallvec, SmallVec};
use tracing::info;

use crate::{
    components::{
        block_proposer::DeployInfo,
        consensus::{ClContext, ProposedBlock},
        fetcher::FetchResult,
        Component,
    },
    effect::{
        requests::{BlockValidationRequest, FetcherRequest, StorageRequest},
        EffectBuilder, EffectExt, EffectOptionExt, Effects, Responder,
    },
    types::{
        appendable_block::AppendableBlock, Approval, Block, Chainspec, Deploy, DeployHash,
        DeployOrTransferHash, DeployWithApprovals, Timestamp,
    },
    NodeRng,
};
use keyed_counter::KeyedCounter;

#[derive(DataSize, Debug, Display, Clone, Hash, Eq, PartialEq)]
pub(crate) enum ValidatingBlock {
    #[display(fmt = "{}", _0.display())]
    Block(Box<Block>),
    #[display(fmt = "{}", _0.display())]
    ProposedBlock(Box<ProposedBlock<ClContext>>),
}

impl From<Block> for ValidatingBlock {
    fn from(block: Block) -> ValidatingBlock {
        ValidatingBlock::Block(Box::new(block))
    }
}

impl From<ProposedBlock<ClContext>> for ValidatingBlock {
    fn from(proposed_block: ProposedBlock<ClContext>) -> ValidatingBlock {
        ValidatingBlock::ProposedBlock(Box::new(proposed_block))
    }
}

impl ValidatingBlock {
    fn timestamp(&self) -> Timestamp {
        match self {
            ValidatingBlock::Block(block) => block.timestamp(),
            ValidatingBlock::ProposedBlock(pb) => pb.context().timestamp(),
        }
    }

    fn deploy_hashes(&self) -> Box<dyn Iterator<Item = &DeployHash> + '_> {
        match self {
            ValidatingBlock::Block(block) => Box::new(block.deploy_hashes().iter()),
            ValidatingBlock::ProposedBlock(pb) => Box::new(pb.value().deploy_hashes()),
        }
    }

    fn transfer_hashes(&self) -> Box<dyn Iterator<Item = &DeployHash> + '_> {
        match self {
            ValidatingBlock::Block(block) => Box::new(block.transfer_hashes().iter()),
            ValidatingBlock::ProposedBlock(pb) => Box::new(pb.value().transfer_hashes()),
        }
    }

    fn deploys_and_transfers_iter(
        &self,
    ) -> Box<dyn Iterator<Item = (DeployOrTransferHash, Option<BTreeSet<Approval>>)> + '_> {
        match self {
            ValidatingBlock::Block(block) => {
                let deploys = block
                    .deploy_hashes()
                    .iter()
                    .map(|hash| (DeployOrTransferHash::Deploy(*hash), None));
                let transfers = block
                    .transfer_hashes()
                    .iter()
                    .map(|hash| (DeployOrTransferHash::Transfer(*hash), None));
                Box::new(deploys.chain(transfers))
            }
            ValidatingBlock::ProposedBlock(pb) => {
                let deploys = pb.value().deploys().iter().map(|dwa| {
                    (
                        DeployOrTransferHash::Deploy(*dwa.deploy_hash()),
                        Some(dwa.approvals().clone()),
                    )
                });
                let transfers = pb.value().transfers().iter().map(|dwa| {
                    (
                        DeployOrTransferHash::Transfer(*dwa.deploy_hash()),
                        Some(dwa.approvals().clone()),
                    )
                });
                Box::new(deploys.chain(transfers))
            }
        }
    }
}

/// Block validator component event.
#[derive(Debug, From, Display)]
pub(crate) enum Event<I> {
    /// A request made of the block validator component.
    #[from]
    Request(BlockValidationRequest<I>),

    /// A deploy has been successfully found.
    #[display(fmt = "{} found", dt_hash)]
    DeployFound {
        dt_hash: DeployOrTransferHash,
        approvals: BTreeSet<Approval>,
        deploy_info: Box<DeployInfo>,
    },

    /// A request to find a specific deploy, potentially from a peer, failed.
    #[display(fmt = "{} missing", _0)]
    DeployMissing(DeployOrTransferHash),

    /// Deploy was invalid. Unable to convert to a deploy type.
    #[display(fmt = "{} invalid", _0)]
    CannotConvertDeploy(DeployOrTransferHash),
}

/// State of the current process of block validation.
///
/// Tracks whether or not there are deploys still missing and who is interested in the final result.
#[derive(DataSize, Debug)]
pub(crate) struct BlockValidationState {
    /// Appendable block ensuring that the deploys satisfy the validity conditions.
    appendable_block: AppendableBlock,
    /// The deploys that have not yet been "crossed off" the list of potential misses.
    /// The set of approvals is `Some` if the deploy was included in a block received via
    /// consensus, with a set of approvals that would be finalized with the block.
    missing_deploys: HashMap<DeployOrTransferHash, Option<BTreeSet<Approval>>>,
    /// A list of responders that are awaiting an answer.
    responders: SmallVec<[Responder<bool>; 2]>,
}

impl BlockValidationState {
    fn respond<REv>(&mut self, value: bool) -> Effects<REv> {
        self.responders
            .drain(..)
            .flat_map(|responder| responder.respond(value).ignore())
            .collect()
    }
}

#[derive(DataSize, Debug)]
pub(crate) struct BlockValidator<I> {
    /// Chainspec loaded for deploy validation.
    #[data_size(skip)]
    chainspec: Arc<Chainspec>,
    /// State of validation of a specific block.
    validation_states: HashMap<ValidatingBlock, BlockValidationState>,
    /// Number of requests for a specific deploy hash still in flight.
    in_flight: KeyedCounter<DeployHash>,
    _phantom_data: PhantomData<I>,
}

impl<I> BlockValidator<I>
where
    I: Clone + Debug + Send + 'static + Send,
{
    /// Creates a new block validator instance.
    pub(crate) fn new(chainspec: Arc<Chainspec>) -> Self {
        BlockValidator {
            chainspec,
            validation_states: HashMap::new(),
            in_flight: KeyedCounter::default(),
            _phantom_data: PhantomData,
        }
    }

    /// Prints a log message about an invalid block with duplicated deploys.
    fn log_block_with_replay(&self, sender: I, block: &ValidatingBlock) {
        let mut deploy_counts = BTreeMap::new();
        for (dt_hash, _) in block.deploys_and_transfers_iter() {
            *deploy_counts.entry(dt_hash).or_default() += 1;
        }
        let duplicates = deploy_counts
            .into_iter()
            .filter_map(|(dt_hash, count): (DeployOrTransferHash, usize)| {
                (count > 1).then(|| format!("{} * {}", count, dt_hash))
            })
            .join(", ");
        info!(
            peer_id=?sender, %duplicates,
            "received invalid block containing duplicated deploys"
        );
    }
}

impl<I, REv> Component<REv> for BlockValidator<I>
where
    I: Clone + Debug + Send + PartialEq + Eq + 'static,
    REv: From<Event<I>>
        + From<BlockValidationRequest<I>>
        + From<FetcherRequest<I, Deploy>>
        + From<StorageRequest>
        + Send,
{
    type Event = Event<I>;
    type ConstructionError = Infallible;

    fn handle_event(
        &mut self,
        effect_builder: EffectBuilder<REv>,
        _rng: &mut NodeRng,
        event: Self::Event,
    ) -> Effects<Self::Event> {
        let mut effects = Effects::new();
        match event {
            Event::Request(BlockValidationRequest {
                block,
                sender,
                responder,
            }) => {
                let deploy_count = block.deploy_hashes().count() + block.transfer_hashes().count();
                if deploy_count == 0 {
                    // If there are no deploys, return early.
                    return responder.respond(true).ignore();
                }
                // Collect the deploys in a map. If they are fewer now, then there was a duplicate!
                let block_deploys: HashMap<_, _> = block.deploys_and_transfers_iter().collect();
                if block_deploys.len() != deploy_count {
                    self.log_block_with_replay(sender, &block);
                    return responder.respond(false).ignore();
                }

                let block_timestamp = block.timestamp();
                let state = self
                    .validation_states
                    .entry(block)
                    .or_insert(BlockValidationState {
                        appendable_block: AppendableBlock::new(
                            self.chainspec.deploy_config,
                            block_timestamp,
                        ),
                        missing_deploys: block_deploys.clone(),
                        responders: smallvec![],
                    });

                if state.missing_deploys.is_empty() {
                    // Block has already been validated successfully, early return to caller.
                    return responder.respond(true).ignore();
                }

                // We register ourselves as someone interested in the ultimate validation result.
                state.responders.push(responder);

                effects.extend(block_deploys.into_iter().flat_map(|(dt_hash, _)| {
                    // For every request, increase the number of in-flight...
                    self.in_flight.inc(&dt_hash.into());
                    // ...then request it.
                    fetch_deploy(effect_builder, dt_hash, sender.clone())
                }));
            }
            Event::DeployFound {
                dt_hash,
                approvals,
                deploy_info,
            } => {
                // We successfully found a hash. Decrease the number of outstanding requests.
                self.in_flight.dec(&dt_hash.into());

                // If a deploy is received for a given block that makes that block invalid somehow,
                // mark it for removal.
                let mut invalid = Vec::new();

                // Our first pass updates all validation states, crossing off the found deploy.
                for (key, state) in self.validation_states.iter_mut() {
                    if let Some(maybe_approvals) = state.missing_deploys.remove(&dt_hash) {
                        // If we had approvals from a proposed block stored here, they should take
                        // precedence over the ones returned in the response.
                        let approvals = maybe_approvals.unwrap_or_else(|| approvals.clone());
                        // If the deploy is of the wrong type or would be invalid for this block,
                        // notify everyone still waiting on it that all is lost.
                        let add_result = match dt_hash {
                            DeployOrTransferHash::Deploy(hash) => {
                                state.appendable_block.add_deploy(
                                    DeployWithApprovals::new(hash, approvals.clone()),
                                    &*deploy_info,
                                )
                            }
                            DeployOrTransferHash::Transfer(hash) => {
                                state.appendable_block.add_transfer(
                                    DeployWithApprovals::new(hash, approvals.clone()),
                                    &*deploy_info,
                                )
                            }
                        };
                        if let Err(err) = add_result {
                            info!(block = ?key, %dt_hash, ?deploy_info, ?err, "block invalid");
                            invalid.push(key.clone());
                        }
                    }
                }

                // Now we remove all states that have finished and notify the requesters.
                self.validation_states.retain(|key, state| {
                    if invalid.contains(key) {
                        effects.extend(state.respond(false));
                        return false;
                    }
                    if state.missing_deploys.is_empty() {
                        // This one is done and valid.
                        effects.extend(state.respond(true));
                        return false;
                    }
                    true
                });
            }
            Event::DeployMissing(dt_hash) => {
                info!(%dt_hash, "request to download deploy timed out");
                // A deploy failed to fetch. If there is still hope (i.e. other outstanding
                // requests), we just ignore this little accident.
                if self.in_flight.dec(&dt_hash.into()) != 0 {
                    return Effects::new();
                }

                self.validation_states.retain(|key, state| {
                    if !state.missing_deploys.contains_key(&dt_hash) {
                        return true;
                    }

                    // Notify everyone still waiting on it that all is lost.
                    info!(block = ?key, %dt_hash, "could not validate the deploy. block is invalid");
                    // This validation state contains a deploy hash we failed to fetch from all
                    // sources, it can never succeed.
                    effects.extend(state.respond(false));
                    false
                });
            }
            Event::CannotConvertDeploy(dt_hash) => {
                // Deploy is invalid. There's no point waiting for other in-flight requests to
                // finish.
                self.in_flight.dec(&dt_hash.into());

                self.validation_states.retain(|key, state| {
                    if state.missing_deploys.contains_key(&dt_hash) {
                        // Notify everyone still waiting on it that all is lost.
                        info!(
                            block = ?key, %dt_hash,
                            "could not convert deploy to deploy type. block is invalid"
                        );
                        // This validation state contains a failed deploy hash, it can never
                        // succeed.
                        effects.extend(state.respond(false));
                        false
                    } else {
                        true
                    }
                });
            }
        }
        effects
    }
}

/// Returns effects that fetch the deploy and validate it.
fn fetch_deploy<REv, I>(
    effect_builder: EffectBuilder<REv>,
    dt_hash: DeployOrTransferHash,
    sender: I,
) -> Effects<Event<I>>
where
    REv: From<Event<I>>
        + From<BlockValidationRequest<I>>
        + From<StorageRequest>
        + From<FetcherRequest<I, Deploy>>
        + Send,
    I: Clone + Send + PartialEq + Eq + 'static,
{
    let validate_deploy = move |result: FetchResult<Deploy, I>| match result {
        FetchResult::FromStorage(deploy) | FetchResult::FromPeer(deploy, _) => {
            (deploy.deploy_or_transfer_hash() == dt_hash)
                .then(|| deploy)
                .and_then(|deploy| {
                    deploy
                        .deploy_info()
                        .ok()
                        .map(|deploy_info| (deploy_info, deploy.approvals().clone()))
                })
                .map_or(
                    Event::CannotConvertDeploy(dt_hash),
                    |(deploy_info, approvals)| Event::DeployFound {
                        dt_hash,
                        approvals,
                        deploy_info: Box::new(deploy_info),
                    },
                )
        }
    };

    effect_builder
        .fetch_deploy(dt_hash.into(), sender)
        .map_or_else(validate_deploy, move || Event::DeployMissing(dt_hash))
}
