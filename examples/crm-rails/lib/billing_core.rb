# Namespace root for the Billing Core integration adapter (BC-TASK-093).
# Explicitly requires the parts so nested error constants resolve without
# Zeitwerk needing one file per constant.
module BillingCore
end

require "billing_core/integration"
require "billing_core/client"
require "billing_core/provisioning"
require "billing_core/provider"
