# Tennis Match Simulator

A probabilistic tennis match simulator for predicting match outcomes and comparing predictions against betting lines.

## Project Structure

```
tennis-simulator/
├── src/tennis_simulator/    # Core Python simulator package
├── r_analysis/              # R scripts for statistical analysis
├── data/
│   ├── raw/                 # Original data files
│   └── processed/           # Cleaned/transformed data
├── notebooks/               # Jupyter and RMarkdown notebooks
├── scripts/                 # Utility scripts
└── tests/                   # Test suite
```

## Setup

### Python

```bash
python -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate
pip install -e ".[dev]"
```

### R

```r
# Install renv if needed
install.packages("renv")
renv::restore()
```

## Usage

*Coming soon*

## License

MIT
