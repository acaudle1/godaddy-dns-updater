# Security Policy

## Supported Versions

This repository currently supports the latest version on the default branch.

## Reporting a Vulnerability

Please do not open public GitHub issues for security problems.

Instead, report privately to the repository owner with:

- A clear description of the issue
- Steps to reproduce
- Potential impact
- Any suggested mitigation

## Sensitive Data Handling

This project is designed to work with API credentials and tenant data. Before publishing changes:

- Never commit `.env` or any file containing secrets
- Never commit runtime reports from `output/*.json`
- Rotate credentials immediately if secrets were ever committed or shared
