// billingctl is the official command-line client and MCP server for
// Billing Core (SPEC §12.2.3, BC-US-157/158, INV-043/044/045).
package main

import (
	"os"

	"github.com/revryn/billing-core/internal/commands"
)

func main() {
	os.Exit(commands.Main(os.Args[1:]))
}
