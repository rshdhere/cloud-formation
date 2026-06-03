![CloudFormation repository architecture](docs/cloudformation_repo_architecture.svg)

## Deployment bootstrap

The GitHub Actions deploy workflow uses AWS OIDC by default. For the first run, or if the OIDC provider has not been created yet, set repository secrets named `AWS_BOOTSTRAP_ACCESS_KEY_ID` and `AWS_BOOTSTRAP_SECRET_ACCESS_KEY` so the workflow can deploy the shared security stack that creates the OIDC provider and deployment role.

The workflow switches back to OIDC immediately after `shared-security` is deployed, so the temporary bootstrap user does not need CloudWatch or SNS permissions.
