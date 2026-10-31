# Upstream provenance

Source: [Microsoft SRE Agent VM/Cosmos DB lab](https://github.com/microsoft/sre-agent/tree/f3dccc6bae8c932ff4f21e6d4117e14285da4db3/labs/vm-cosmosdb),
commit `f3dccc6bae8c932ff4f21e6d4117e14285da4db3`.

The upstream Scenario C removes tags, adds an insecure SSH NSG rule and attempts
to disable diagnostics on a database VM. Its current main template instead uses
one application VM and Cosmos DB. The SSH rule also conflicts with an existing
inbound priority. None of these faults intentionally breaks the storefront.

OrderFlow adapts the VM, managed-identity Cosmos, configuration baseline and
approval-led drift investigation concepts. The Python application, separated
portal, scoped network fault, owned lifecycle and acceptance contracts are new.
The source is not a submodule and no runtime download from upstream is required.

Differences are intentional:

- Availability-affecting drift replaces public-SSH exposure.
- One existing allow rule becomes a deny, retaining a precise repair scope.
- App Service keeps the presentation surface available during the failure.
- No tag/diagnostics fault, CPU load, memory pressure or scheduled remediation.
- Native pre-execution approval replaces the upstream final-response Stop hook.
- No broad VM/Network Contributor assignment for the SRE action identity.
- Root Python tooling replaces an additional Node development toolchain.

## MIT notice

Copyright (c) Microsoft Corporation.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
