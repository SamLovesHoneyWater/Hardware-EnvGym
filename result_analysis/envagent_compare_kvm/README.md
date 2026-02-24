# EnvAgent KVM Logs Comparison

- Metrics compared: CPU, RAM, Disk, GPU
- Series in each plot: Agent Predicted, Actual Required, Actually Reserved
- Repo count: 27
- Actual reserved sufficient ratio (all 4 resources): 0.8519 (23/27)
- AI predicted sufficient ratio (all 4 resources): 0.2222 (6/27)
- Average reserved redundancy (%): {'cpu': 2714.814814814815, 'ram': 8403.703703703704, 'disk': 24677.777777777777, 'gpu': None}
- Average predicted redundancy (%): {'cpu': 118.51851851851852, 'ram': 437.962962962963, 'disk': 101.38888888888889, 'gpu': None}

## Files
- envagent_vs_actual_table.csv
- sufficiency_summary.json
- cpu_comparison.png
- ram_comparison.png
- disk_comparison.png
- gpu_comparison.png