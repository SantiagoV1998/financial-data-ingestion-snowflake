q() { snow sql -c nuaav --format json -q "$1" 2>/dev/null; }
echo "{"
echo '"rules":' ; q "SELECT rule_code, severity, entity, COUNT(*) AS findings FROM silver.dq_quarantine GROUP BY rule_code, severity, entity ORDER BY findings DESC;"
echo ',"by_client":' ; q "SELECT source_system, severity, COUNT(*) AS findings FROM silver.dq_quarantine GROUP BY source_system, severity;"
echo ',"coverage":' ; q "SELECT expected_rule, COUNT(*) AS labelled, SUM(IFF(outcome='DETECTED',1,0)) AS detected FROM silver.v_rule_coverage GROUP BY expected_rule ORDER BY labelled DESC;"
echo ',"classification":' ; q "SELECT classification, COUNT(*) AS labels FROM silver.v_label_classification GROUP BY classification;"
echo ',"variance":' ; q "SELECT source_system, COUNT(*) AS txns, SUM(IFF(amount_variance IS NOT NULL AND ABS(amount_variance)>0.01,1,0)) AS with_variance, ROUND(SUM(ABS(COALESCE(amount_variance,0))),2) AS total_abs_variance FROM gold.fact_transaction GROUP BY source_system;"
echo ',"client_rows":' ; q "SELECT source_system, COUNT(*) AS transactions FROM gold.fact_transaction GROUP BY source_system;"
echo "}"
