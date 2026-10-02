# Testing Results

## Test Environment

| Attribute | Value |
|-----------|-------|
| Date | 2026-11-25 |
| OS | Windows 11 |
| Python | 3.12.8 |
| Flask | 3.1.1 |
| Database | SQLite (in-memory, testing mode) |
| AWS Deployed | No (Profile A — local only) |

---

## Local Test Execution

### Command
```powershell
cd application
.\.venv\Scripts\Activate.ps1
pytest -v --tb=short
```

### Results — 48/48 PASSED ✅

```
tests/test_config.py::TestConfigMapping::test_all_keys_present PASSED
tests/test_config.py::TestConfigMapping::test_testing_uses_in_memory_db PASSED
tests/test_config.py::TestConfigMapping::test_testing_has_no_debug_false PASSED
tests/test_config.py::TestConfigMapping::test_development_debug_enabled PASSED
tests/test_config.py::TestConfigMapping::test_production_debug_disabled PASSED
tests/test_config.py::TestProductionValidation::test_validate_raises_when_missing_vars PASSED
tests/test_config.py::TestProductionValidation::test_validate_passes_when_vars_present PASSED
tests/test_health.py::TestHealthEndpoint::test_health_returns_200 PASSED
tests/test_health.py::TestHealthEndpoint::test_health_response_structure PASSED
tests/test_health.py::TestHealthEndpoint::test_health_status_is_healthy PASSED
tests/test_health.py::TestHealthEndpoint::test_health_database_check_passes PASSED
tests/test_health.py::TestHealthEndpoint::test_health_app_check_passes PASSED
tests/test_health.py::TestInfoEndpoint::test_info_returns_200 PASSED
tests/test_health.py::TestInfoEndpoint::test_version_alias_returns_200 PASSED
tests/test_health.py::TestInfoEndpoint::test_info_structure PASSED
tests/test_health.py::TestInfoEndpoint::test_info_app_name PASSED
tests/test_health.py::TestRootEndpoint::test_root_returns_200 PASSED
tests/test_health.py::TestRootEndpoint::test_root_contains_links PASSED
tests/test_models.py::TestTaskModel::test_task_creation PASSED
tests/test_models.py::TestTaskModel::test_to_dict_structure PASSED
tests/test_models.py::TestTaskModel::test_to_dict_status_is_string PASSED
tests/test_models.py::TestTaskModel::test_task_status_enum_values PASSED
tests/test_models.py::TestTaskModel::test_task_repr PASSED
tests/test_models.py::TestTaskPersistence::test_create_and_retrieve PASSED
tests/test_models.py::TestTaskPersistence::test_delete_task PASSED
tests/test_tasks.py::TestListTasks::test_returns_200 PASSED
tests/test_tasks.py::TestListTasks::test_returns_list_structure PASSED
tests/test_tasks.py::TestListTasks::test_filter_by_valid_status PASSED
tests/test_tasks.py::TestListTasks::test_filter_by_invalid_status_returns_400 PASSED
tests/test_tasks.py::TestListTasks::test_filter_by_priority PASSED
tests/test_tasks.py::TestCreateTask::test_creates_task_with_minimal_payload PASSED
tests/test_tasks.py::TestCreateTask::test_creates_task_with_full_payload PASSED
tests/test_tasks.py::TestCreateTask::test_missing_title_returns_400 PASSED
tests/test_tasks.py::TestCreateTask::test_empty_title_returns_400 PASSED
tests/test_tasks.py::TestCreateTask::test_invalid_status_returns_400 PASSED
tests/test_tasks.py::TestCreateTask::test_invalid_priority_returns_400 PASSED
tests/test_tasks.py::TestCreateTask::test_no_body_returns_400 PASSED
tests/test_tasks.py::TestCreateTask::test_response_includes_id PASSED
tests/test_tasks.py::TestCreateTask::test_response_includes_timestamps PASSED
tests/test_tasks.py::TestGetTask::test_returns_existing_task PASSED
tests/test_tasks.py::TestGetTask::test_nonexistent_task_returns_404 PASSED
tests/test_tasks.py::TestUpdateTask::test_full_update PASSED
tests/test_tasks.py::TestUpdateTask::test_nonexistent_task_returns_404 PASSED
tests/test_tasks.py::TestPartialUpdateTask::test_partial_status_update PASSED
tests/test_tasks.py::TestPartialUpdateTask::test_partial_title_update PASSED
tests/test_tasks.py::TestPartialUpdateTask::test_nonexistent_task_returns_404 PASSED
tests/test_tasks.py::TestDeleteTask::test_deletes_task PASSED
tests/test_tasks.py::TestDeleteTask::test_nonexistent_task_returns_404 PASSED

========================= 48 passed in 4.23s =========================
```

### Coverage Report
| Module | Statements | Missed | Coverage |
|--------|-----------|--------|----------|
| `app/__init__.py` | 40 | 6 | 85% |
| `app/config.py` | 28 | 0 | **100%** |
| `app/models/__init__.py` | 1 | 0 | **100%** |
| `app/models/task.py` | 23 | 0 | **100%** |
| `app/routes/health.py` | 30 | 5 | 83% |
| `app/routes/tasks.py` | 134 | 29 | 78% |
| `app/utils/metadata.py` | 35 | 13 | 63% |
| **TOTAL** | **291** | **53** | **82%** |

---

## Terraform Validation

### Commands
```powershell
cd terraform
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
```

### Results
| Check | Status |
|-------|--------|
| `terraform init` | ✅ Providers installed |
| `terraform fmt` | ✅ All files correctly formatted |
| `terraform validate` | ✅ Configuration is valid |

---

## Infrastructure Tests (Pending AWS Deployment)

The following tests require Profile B to be deployed and are **not yet executed**.

| Test | Method | Status |
|------|--------|--------|
| ALB health check routing | `aws elbv2 describe-target-health` | ⏳ Pending |
| Auto Scaling scale-out | Load test with Locust, observe ASG | ⏳ Pending |
| Instance replacement | Terminate instance manually, observe replacement | ⏳ Pending |
| Load balancing across AZs | Check `/info` for different `instance_id` / `availability_zone` | ⏳ Pending |
| DB connectivity | Connect via SSM Session Manager, run psql | ⏳ Pending |
| RDS failover | Reboot with forced failover, measure downtime | ⏳ Pending |
| WAF rate limiting | Send >2000 req/5min, verify 403 | ⏳ Pending |
| CloudWatch alarm | Trigger CPU alarm, verify SNS email | ⏳ Pending |
| Security group isolation | Attempt direct EC2 access, verify blocked | ⏳ Pending |

---

## Load Testing Instructions (Locust)

Install Locust and run a load test against the deployed ALB:

```powershell
pip install locust
```

Create `locustfile.py`:
```python
from locust import HttpUser, task, between

class TaskUser(HttpUser):
    wait_time = between(1, 3)

    @task(3)
    def list_tasks(self):
        self.client.get("/api/tasks")

    @task(2)
    def health_check(self):
        self.client.get("/health")

    @task(1)
    def create_task(self):
        self.client.post("/api/tasks", json={
            "title": "Load test task",
            "priority": "low"
        })
```

Run:
```powershell
locust --host=http://<ALB_DNS_NAME> --users 50 --spawn-rate 5
# Open http://localhost:8089 for the web UI
```

Observe:
1. ASG `GroupInServiceInstances` metric in CloudWatch → should increase.
2. ALB `RequestCount` metric → should show distributed load.
3. `/info` endpoint → should return different `instance_id` values.
