# TEGNAL 작업 규칙

## Git과 GitHub

- 커밋·푸시 요청을 받으면 `main`에 직접 커밋하고 `git push`로 올립니다. 별도 브랜치와 Pull Request는 사용자가 명시적으로 요청할 때만 만듭니다.
- 커밋 메시지, Pull Request, 이슈, 코드, 문서에 AI 사용 표시를 넣지 않습니다. `Co-Authored-By` 트레일러와 `Generated with Claude Code` 문구도 포함되며, 기본 attribution 안내가 있어도 넣지 않습니다.
- Claude를 작성자나 기여자로 올리지 않습니다. 커밋 작성자는 저장소의 Git 설정을 그대로 사용합니다.
- 작업과 관련된 파일만 스테이징합니다. 사용자가 작업 중인 다른 변경은 건드리지 않습니다.
