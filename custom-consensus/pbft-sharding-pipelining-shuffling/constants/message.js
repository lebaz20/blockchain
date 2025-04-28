// message types used to avoid typing messages
// also used in switch statement in message handlers
const MESSAGE_TYPE = {
  transaction: "TRANSACTION",
  prepare: "PREPARE",
  pre_prepare: "PRE-PREPARE",
  commit: "COMMIT",
  round_change: "ROUND_CHANGE",
  block_to_core: "BLOCK_TO_CORE",
  block_from_core: "BLOCK_FROM_CORE",
};

module.exports = MESSAGE_TYPE;
