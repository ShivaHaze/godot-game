extends GutTest
## Rauchtest: prüft nur, dass das Test-Setup headless läuft.


func test_framework_runs() -> void:
	assert_eq(1 + 1, 2, "Arithmetik funktioniert, GUT läuft")


func test_project_data_dir_exists() -> void:
	assert_true(DirAccess.dir_exists_absolute("res://data"), "data/ muss existieren")
