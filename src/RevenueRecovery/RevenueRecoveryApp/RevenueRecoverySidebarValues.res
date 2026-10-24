open SidebarTypes

let defaultPath = "/v2/recovery/invoices"

let revenueRecoveryHome = {
  Link({
    name: "Home",
    link: `/v2/recovery`,
    access: Access,
    icon: "nd-home",
  })
}

let revenueRecoveryInvoices = {
  Link({
    name: "Invoices",
    link: `/v2/recovery/invoices`,
    access: Access,
    icon: "nd-operations",
  })
}

let revenueRecoverySummary = {
  Link({
    name: "Configuration Details",
    link: `/v2/recovery/summary`,
    access: Access,
    icon: "nd-connectors",
  })
}

// Rev Rec Simulator pages (flag `dev_recovery_simulator`)
let homePath = "/v2/recovery/home"
let simulatorStoryPath = "/v2/recovery/simulator/story"
let simulatorTourPath = "/v2/recovery/simulator/tour"

let revenueRecoverySimulatorHome = {
  Link({
    name: "Home",
    link: homePath,
    access: Access,
    icon: "nd-home",
  })
}

let revenueRecoverySimulatorStory = {
  Link({
    name: "Invoice Story",
    link: simulatorStoryPath,
    access: Access,
    icon: "nd-workflow",
  })
}

let revenueRecoverySimulatorTour = {
  Link({
    name: "Feature Tour",
    link: simulatorTourPath,
    access: Access,
    icon: "nd-overview",
  })
}

let recoverySidebars = (_isLiveMode, ~showSimulator) => {
  showSimulator
    ? [
        revenueRecoverySimulatorHome,
        revenueRecoveryInvoices,
        revenueRecoverySimulatorStory,
        revenueRecoverySimulatorTour,
        revenueRecoverySummary,
      ]
    : [revenueRecoveryInvoices, revenueRecoverySummary]
}
