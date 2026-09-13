# Query results (SQLite 3.45.1)


## F1 Top 10 audio tracks by number of distinct videos in the last 7 days.

Rows returned: 10    Runtime: 51 ms

| track_id | title | kind | n_videos |
|---|---|---|---|
| 1 | Marching 1 | licensed | 74 |
| 2 | Drift 2 | licensed | 41 |
| 3 | Glow 3 | licensed | 21 |
| 7 | Cat Walk 7 | licensed | 10 |
| 9 | Bloom 9 | licensed | 10 |

## F2 Watch hours and completion rate per creator, live clips only.

Rows returned: 625    Runtime: 1,056 ms

| creator_id | handle | live_impressions | watch_hours | completion_rate |
|---|---|---|---|---|
| 2527 | pemax328 | 25279 | 53.178 | 0.0489 |
| 3453 | gita265 | 11749 | 24.12 | 0.0466 |
| 590 | dev7 | 9289 | 20.956 | 0.0466 |
| 83 | aaravvlogs192 | 5462 | 18.189 | 0.0482 |
| 3277 | sita.490 | 7585 | 18.043 | 0.0519 |

## F3a Videos with no audio track, written with NOT IN.

Rows returned: 0    Runtime: 2 ms

| video_id | audio_track_id |
|---|---|

## F3b The same question with NOT EXISTS.

Rows returned: 7,321    Runtime: 7 ms

| video_id | audio_track_id |
|---|---|
| 1 |  |
| 5 |  |
| 7 |  |
| 10 |  |
| 16 |  |

## F4 Users who liked and then retracted the like on the same clip within 60 seconds.

Rows returned: 300    Runtime: 7 ms

| user_id | handle | video_id | liked_at | retracted_at | seconds_between |
|---|---|---|---|---|---|
| 1638 | kiran576 | 15258 | 2026-07-22T14:15:25Z | 2026-07-22T14:15:28Z | 3 |
| 4137 | tara944 | 19444 | 2026-07-24T18:31:37Z | 2026-07-24T18:31:40Z | 3 |
| 4910 | suman_815 | 15078 | 2026-08-25T19:32:43Z | 2026-08-25T19:32:46Z | 3 |
| 3864 | nIshAx659 | 10988 | 2026-09-07T11:36:30Z | 2026-09-07T11:36:33Z | 3 |
| 2027 | leela.827 | 12499 | 2026-06-11T21:07:07Z | 2026-06-11T21:07:11Z | 4 |

## F5 Videos whose caption carries the hashtag #study (case-insensitive,

Rows returned: 727    Runtime: 37 ms

| video_id | caption |
|---|---|
| 29 | finish my to.#Study, #FuNNY, #TAG250 |
| 56 | prank wait part roommate lives #Dog! #VIRAL #fyp, #study |
| 93 | for finish rain finally end late head sound roommate #study! |
| 95 | this my it end night cat campus recipe late try end  #Study |
| 124 | pov finish dorm try walk a my exam in.#Fyp #tag64, #tag65! #exam #study |

## F6a Users who were shown creator 2527's clips but never engaged with any of them.

Rows returned: 3,672    Runtime: 74 ms

| user_id |
|---|
| 1 |
| 2 |
| 3 |
| 4 |
| 5 |

## F6b Signal roll-up with UNION: videos that received a like or a save.

Rows returned: 5,190    Runtime: 17 ms

| video_id |
|---|
| 2 |
| 3 |
| 5 |
| 6 |
| 10 |

## F6c The same roll-up with UNION ALL.

Rows returned: 10,045    Runtime: 16 ms

| video_id |
|---|
| 6315 |
| 3876 |
| 5923 |
| 7207 |
| 19798 |

## F7 Cost of each agent session last month (August 2026), broken out by

Rows returned: 32    Runtime: 6 ms

| session_id | user_id | template | template_version | turns | version_cost_usd | session_cost_usd |
|---|---|---|---|---|---|---|
| 1299 | 3667 | conversational_search | 15 | 3 | 0.004783 | 0.004783 |
| 983 | 3345 | conversational_search | 15 | 3 | 0.003998 | 0.003998 |
| 1375 | 118 | conversational_search | 15 | 4 | 0.003264 | 0.003264 |
| 1198 | 950 | conversational_search | 15 | 3 | 0.003143 | 0.003143 |
| 1929 | 1872 | conversational_search | 15 | 2 | 0.003103 | 0.003103 |

## F8 Videos whose moderation state changed more than twice, with the full

Rows returned: 973    Runtime: 49 ms

| video_id | state_changes | transitions | first_decision | last_decision |
|---|---|---|---|---|
| 15 | 3 | pending > live > demoted > live | 2026-06-11T15:33:57Z | 2026-06-15T06:56:55Z |
| 19 | 3 | pending > live > demoted > live | 2026-04-24T20:33:38Z | 2026-04-26T17:43:32Z |
| 94 | 3 | pending > live > demoted > live | 2026-08-11T12:59:41Z | 2026-08-17T03:03:08Z |
| 97 | 3 | pending > live > demoted > taken_down | 2026-03-13T21:24:45Z | 2026-03-19T20:07:48Z |
| 131 | 3 | pending > live > demoted > taken_down | 2026-09-04T09:48:18Z | 2026-09-07T03:01:53Z |

## F9 Each user's longest streak of consecutive active days.

Rows returned: 4,921    Runtime: 625 ms

| user_id | handle | longest_streak | streak_start | streak_end |
|---|---|---|---|---|
| 287 | pema22367 | 100 | 2026-06-01 | 2026-09-08 |
| 468 | hariclips579 | 100 | 2026-06-01 | 2026-09-08 |
| 522 | rohan7 | 100 | 2026-06-01 | 2026-09-08 |
| 539 | suman_official617 | 100 | 2026-06-01 | 2026-09-08 |
| 578 | Leelaclips66 | 100 | 2026-06-01 | 2026-09-08 |

## F10 Creators ranked by 7-day rolling watch time as of "now", with

Rows returned: 625    Runtime: 171 ms

| rnk | creator_id | handle | this_week_hours | last_week_hours | wow_change_hours |
|---|---|---|---|---|---|
| 1 | 2512 | ishan22283 | 11.11 | 0.11 | 10.99 |
| 2 | 2527 | pemax328 | 9.53 | 7.72 | 1.82 |
| 3 | 3453 | gita265 | 5.37 | 3.12 | 2.26 |
| 4 | 590 | dev7 | 4.21 | 3.11 | 1.1 |
| 5 | 3277 | sita.490 | 3.93 | 2.36 | 1.57 |

## F11 Full nesting tree of tool calls for agent session 1401, with depth.

Rows returned: 40    Runtime: 1 ms

| turn_index | depth | call_tree | call_id | parent_call_id | latency_ms | errored |
|---|---|---|---|---|---|---|
| 2 | 1 | get_user_history | 8261 |  | 433 | 0 |
| 2 | 2 | ..rerank | 8262 | 8261 | 92 | 0 |
| 2 | 2 | ..fetch_trending_audio | 8263 | 8261 | 58 | 0 |
| 2 | 3 | ....search_videos | 8264 | 8263 | 130 | 0 |
| 2 | 4 | ......fetch_trending_audio | 8265 | 8264 | 141 | 0 |

## F12 Sessions where the agent recommended a clip that the user then

Rows returned: 311    Runtime: 449 ms

| session_id | user_id | turn_index | shelf_position | video_id | impression_id | watch_seconds | clip_seconds |
|---|---|---|---|---|---|---|---|
| 19 | 3437 | 1 | 2 | 130 | 296030 | 48.742 | 36.957 |
| 36 | 3702 | 2 | 3 | 3634 | 296052 | 83.048 | 47.527 |
| 36 | 3702 | 2 | 5 | 11891 | 296053 | 39.529 | 37.711 |
| 39 | 2544 | 1 | 8 | 3854 | 296061 | 72.834 | 27.176 |
| 40 | 3167 | 3 | 1 | 3033 | 296063 | 43.354 | 33.142 |

## F13 Turns where the LLM judge scored helpfulness above 4 but the user

Rows returned: 6    Runtime: 0 ms

| turn_id | session_id | session_kind | helpfulness | groundedness | safety | user_rating | user_message |
|---|---|---|---|---|---|---|---|
| 3224 | 1730 | search | 5.0 | 4.99 | 3.77 | -1 | cricket highlights from this week |
| 1217 | 651 | search | 4.47 | 4.3 | 4.08 | -1 | clips using the sunset loop sound |
| 2008 | 1077 | why_this | 4.46 | 4.54 | 4.89 | -1 | why am I seeing this |
| 365 | 199 | search | 4.35 | 5.0 | 4.76 | -1 | only ones with music |
| 3429 | 1843 | search | 4.33 | 4.11 | 4.22 | -1 | find the exam week pov clip |
