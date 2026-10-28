import Foundation

enum ComplexSelectionFixture {
    static let source = #"""
# Product Launch Checklist

The launch includes **three major goals**: improve onboarding, reduce response time, and make the product easier to use. The first release is *not the final version*; we will continue improving it based on user feedback.

## 1. Before the launch

1. **Prepare the product**
   - Verify that new users can complete registration.
   - Check the [help center](https://example.com/help) and update outdated screenshots.
   - Confirm that the response time is below **3 seconds** for common requests.
2. **Prepare the team**
   - Assign one owner to each task.
   - Share the final checklist with the support team.
   - Make sure everyone knows how to report a problem.

> **Important:** If a critical issue appears, pause the launch.
>
> A delayed release is better than a broken experience.

## 2. Metrics to watch

| Metric | Target | Owner |
| --- | --- | --- |
| Registration completion | 80% or higher | Product |
| Average response time | Under 3 seconds | Engineering |
| Support response time | Within 2 hours | Support |

## 3. Technical notes

The configuration key is `launch_enabled`. Do not translate the key name or change the URL in the example below.

```json
{
  "launch_enabled": true,
  "help_url": "https://example.com/help",
  "retry_count": 3
}
```

After launch, review the results every day for the first week. If the numbers are lower than expected, document the issue, identify the cause, and agree on the next action.
"""#
    static let flattened = #"""
# Product Launch Checklist
The launch includes **three major goals**: improve onboarding, reduce response time, and make the product easier to use. The first release is *not the final version*; we will continue improving it based on user feedback.
​​￼## 1. Before the launch
​​￼1. **Prepare the product**   - Verify that new users can complete registration.   - Check the [help center](https://example.com/help) and update outdated screenshots.   - Confirm that the response time is below **3 seconds** for common requests.​​￼2. **Prepare the team**   - Assign one owner to each task.   - Share the final checklist with the support team.   - Make sure everyone knows how to report a problem.
​> **Important:** If a critical issue appears, pause the launch.​>​> A delayed release is better than a broken experience.
​​￼## 2. Metrics to watch
Metric￼￼Target￼Owner￼Registration completion￼80% or higherProductAverage response time￼Under 3 secondsEngineeringSupport response time￼Within 2 hoursSupport￼￼
​​￼## 3. Technical notes
The configuration key is `launch_enabled`. Do not translate the key name or change the URL in the example below.
```json​​￼{  "launch_enabled": true,  "help_url": "https://example.com/help",  "retry_count": 3}```
After launch, review the results every day for the first week. If the numbers are lower than expected, document the issue, identify the cause, and agree on the next action.
"""#
}
