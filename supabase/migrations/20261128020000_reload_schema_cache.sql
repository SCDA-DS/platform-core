-- Refresh the Data API's schema cache so the newly exposed crew schema's tables and functions are found.
notify pgrst, 'reload schema';
