import {describe,expect,it} from "vitest";
import {assertReviewCoverage} from "../src/review-input.ts";
import {RunFailure} from "../src/review-runner.ts";
import type {ReviewInput} from "../src/review-input.ts";
import type {MrDetailJson} from "../src/reviews.ts";
const detail={additions:1,deletions:0,files:[{oldPath:"a",newPath:"a",newFile:false,renamedFile:false,deletedFile:false,diff:"@@ -0,0 +1 @@\n+x"}],filesTruncated:false} as unknown as MrDetailJson;
const input={detail,headSha:"a".repeat(40),baseSha:"b".repeat(40),startSha:"b".repeat(40),versionId:1} satisfies ReviewInput;
describe("assertReviewCoverage",()=>{
 it("accepts complete textual diff input",()=>expect(()=>assertReviewCoverage(input)).not.toThrow());
 it("rejects truncated file coverage",()=>expect(()=>assertReviewCoverage({...input,detail:{...detail,filesTruncated:true}})).toThrow(RunFailure));
 it("rejects omitted diff text",()=>expect(()=>assertReviewCoverage({...input,detail:{...detail,files:[{...detail.files[0]!,diff:null}]}})).toThrow(RunFailure));
 it("requires aggregate line counts",()=>expect(()=>assertReviewCoverage({...input,detail:{...detail,additions:null}})).toThrow(RunFailure));
});
