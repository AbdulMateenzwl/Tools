package converter

import (
    "bytes"
    "encoding/csv"
    "encoding/json"
    "fmt"
    "sort"
)

// JSONToCSV converts a JSON array of objects to CSV
func JSONToCSV(input string) (string, error) {
    var records []map[string]interface{}
    if err := json.Unmarshal([]byte(input), &records); err != nil {
        return "", fmt.Errorf("invalid JSON array: %w", err)
    }
    if len(records) == 0 {
        return "", fmt.Errorf("input must be a non-empty JSON array of objects")
    }

    // Collect all unique headers in sorted order for consistency
    headerSet := map[string]struct{}{}
    for _, r := range records {
        for k := range r {
            headerSet[k] = struct{}{}
        }
    }
    headers := make([]string, 0, len(headerSet))
    for h := range headerSet {
        headers = append(headers, h)
    }
    sort.Strings(headers)

    var buf bytes.Buffer
    w := csv.NewWriter(&buf)

    // Write header row
    if err := w.Write(headers); err != nil {
        return "", fmt.Errorf("write CSV headers: %w", err)
    }

    // Write data rows
    for _, record := range records {
        row := make([]string, len(headers))
        for i, h := range headers {
            if val, ok := record[h]; ok {
                row[i] = fmt.Sprintf("%v", val)
            }
        }
        if err := w.Write(row); err != nil {
            return "", fmt.Errorf("write CSV row: %w", err)
        }
    }
    w.Flush()

    return buf.String(), nil
}

// CSVToJSON converts a CSV string to a JSON array of objects
func CSVToJSON(input string) (string, error) {
    r := csv.NewReader(bytes.NewBufferString(input))
    rows, err := r.ReadAll()
    if err != nil {
        return "", fmt.Errorf("parse CSV: %w", err)
    }
    if len(rows) < 2 {
        return "", fmt.Errorf("CSV must have a header row and at least one data row")
    }

    headers := rows[0]
    var records []map[string]interface{}

    for _, row := range rows[1:] {
        record := map[string]interface{}{}
        for i, val := range row {
            if i < len(headers) {
                record[headers[i]] = val
            }
        }
        records = append(records, record)
    }

    out, err := json.MarshalIndent(records, "", "  ")
    if err != nil {
        return "", fmt.Errorf("marshal JSON: %w", err)
    }

    return string(out), nil
}