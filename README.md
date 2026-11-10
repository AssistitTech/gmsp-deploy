# GMSP: Deploy to Azure

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAssistitTech%2Fgmsp-deploy%2Fmain%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FAssistitTech%2Fgmsp-deploy%2Fmain%2FcreateUiDefinition.json)

This repository holds **only** the files behind GMSP's "Deploy to Azure" button: the Azure template
(`azuredeploy.json`, compiled from `gmsp.bicep`), the guided installation wizard the Azure portal shows
(`createUiDefinition.json`) and the cost guide (`COSTS.md`). There is no GMSP code here: GMSP itself is distributed
privately, and your fork of it deploys the code after the button has created the Azure resources.

Templates for GMSP v1.0.4.

Before you click, read `INSTALL.md` in your copy of GMSP ("Stage 1, option A"). In short: use a Pay-As-You-Go
subscription in which you are Owner, have your fork's name ready, and expect about $25-35 a month with the
recommended sizes ([COSTS.md](COSTS.md)). The wizard shows the price of every choice and never picks a more
expensive size for you.
